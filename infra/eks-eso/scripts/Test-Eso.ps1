[CmdletBinding()]
param([string]$Profile = 'sbhackathon2026-team', [string]$HelmCommand = 'helm')
. "$PSScriptRoot/Common.ps1"
$verificationStart = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$outputs = Get-EsoOutputs
$kubeconfig = New-EsoKubeconfig -Profile $Profile
$manifest = [IO.Path]::GetTempFileName()
$suffix = [guid]::NewGuid().ToString('N').Substring(0,10)
$identityName = "eso-identity-$suffix"; $consumerName = "eso-consumer-$suffix"
$identityAttempted = $false; $consumerAttempted = $false
$reviewName = "eso-review-$suffix"; $reviewConsumerName = "eso-review-consumer-$suffix"
$reviewAttempted = $false; $reviewConsumerAttempted = $false
try {
    $base = @('--kubeconfig',$kubeconfig)
    $operator = $base + @('-n','external-secrets'); $target = $base + @('-n','platform')
    $releases = (Invoke-EsoNative $HelmCommand (@('list','-n','external-secrets','-o','json') + $base)) -join "`n" | ConvertFrom-Json
    if (@($releases | Where-Object { $_.name -eq 'external-secrets' -and $_.chart -eq 'external-secrets-2.12.0' -and $_.status -eq 'deployed' }).Count -ne 1) { throw 'Expected the pinned deployed ESO release.' }
    foreach ($name in @('external-secrets','external-secrets-webhook','external-secrets-cert-controller')) {
        Invoke-EsoNative 'kubectl' ($operator + @('rollout','status',"deployment/$name",'--timeout=180s'))
        $deployment = (Invoke-EsoNative 'kubectl' ($operator + @('get','deployment',$name,'-o','json'))) -join "`n" | ConvertFrom-Json
        if ($deployment.status.readyReplicas -ne 1 -or $deployment.spec.replicas -ne 1 -or $deployment.spec.template.spec.containers[0].image -ne 'ghcr.io/external-secrets/external-secrets:v2.12.0') { throw 'ESO image or readiness differs from the reviewed deployment.' }
    }
    $sa = (Invoke-EsoNative 'kubectl' ($operator + @('get','serviceaccount','external-secrets','-o','json'))) -join "`n" | ConvertFrom-Json
    if ($sa.metadata.annotations.'eks.amazonaws.com/role-arn') { throw 'Do not mix ESO Pod Identity with an IRSA annotation.' }
    foreach ($case in @(
        @('external-secrets','platform','yes'), @('external-secrets','kube-system','no'),
        @('external-secrets-cert-controller','external-secrets','yes'), @('external-secrets-cert-controller','platform','no')
    )) {
        $answer = & kubectl @base auth can-i get secrets "--as=system:serviceaccount:external-secrets:$($case[0])" -n $case[1]
        if (($answer -join '').Trim() -ne $case[2]) { throw 'ESO Secret RBAC does not match the namespace boundary.' }
    }
    Write-Output 'PASS: real Kubernetes RBAC allows only the intended Secret namespaces.'
    $versionsBefore = (Invoke-EsoNative 'aws' @('secretsmanager','describe-secret','--secret-id',$outputs.secret_arn,'--region','ap-northeast-2','--profile',$Profile,'--query','VersionIdsToStages','--output','json','--no-cli-pager')) -join "`n"
    $identityPod = @{apiVersion='v1';kind='Pod';metadata=@{name=$identityName;namespace='external-secrets'};spec=@{
        serviceAccountName='external-secrets';restartPolicy='Never';activeDeadlineSeconds=600
        containers=@(@{name='aws';image='public.ecr.aws/aws-cli/aws-cli:2.37.10';command=@('/bin/sh','-c','sleep 600');resources=@{requests=@{cpu='25m';memory='64Mi'};limits=@{cpu='250m';memory='256Mi'}}})
    }}
    Write-EsoJson $identityPod $manifest
    $identityAttempted = $true
    Invoke-EsoNative 'kubectl' ($base + @('apply','-f',$manifest))
    Invoke-EsoNative 'kubectl' ($operator + @('wait','--for=condition=Ready',"pod/$identityName",'--timeout=180s'))
    $exec = $operator + @('exec',$identityName,'--','aws')
    $identity = (Invoke-EsoNative 'kubectl' ($exec + @('sts','get-caller-identity','--region','ap-northeast-2','--output','json'))) -join "`n" | ConvertFrom-Json
    if ($identity.Account -ne '123456789012' -or $identity.Arn -notlike 'arn:aws:sts::123456789012:assumed-role/oneaction-external-secrets/*') { throw 'Pod did not use the dedicated ESO role.' }
    Invoke-EsoNative 'kubectl' ($exec + @('secretsmanager','describe-secret','--secret-id',$outputs.secret_arn,'--region','ap-northeast-2','--query','OwningService','--output','text')) | Out-Null
    if ($outputs.gitops_token_secret_arn) {
        if ($outputs.gitops_token_secret_arn -notmatch '^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$' -or $outputs.gitops_token_secret_arn -eq $outputs.secret_arn) { throw 'Unexpected GitOps token Secret ARN.' }
        $gitopsMetadata = (Invoke-EsoNative 'kubectl' ($exec + @('secretsmanager','describe-secret','--secret-id',$outputs.gitops_token_secret_arn,'--region','ap-northeast-2','--query','{ARN:ARN,KmsKeyId:KmsKeyId}','--output','json'))) -join "`n" | ConvertFrom-Json
        if ($gitopsMetadata.ARN -ne $outputs.gitops_token_secret_arn -or $gitopsMetadata.KmsKeyId) { throw 'Unexpected GitOps Secret metadata.' }
        # Only ARN/version metadata leaves the AWS CLI process; never print or save the token.
        $gitopsVersion = (Invoke-EsoNative 'kubectl' ($exec + @('secretsmanager','get-secret-value','--secret-id',$outputs.gitops_token_secret_arn,'--version-stage','AWSCURRENT','--region','ap-northeast-2','--query','{ARN:ARN,VersionId:VersionId,VersionStages:VersionStages}','--output','json'))) -join "`n" | ConvertFrom-Json
        if ($gitopsVersion.ARN -ne $outputs.gitops_token_secret_arn -or -not $gitopsVersion.VersionId -or $gitopsVersion.VersionStages -notcontains 'AWSCURRENT') { throw 'GitOps Secret read did not return the current version metadata.' }
        Write-Output 'PASS: same ESO Pod Identity reads the current GitOps token Secret, with no token output.'
    }
    if ($outputs.review_service_secret_arn) {
        $reviewArn = $outputs.review_service_secret_arn
        if ($reviewArn -notmatch '^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-[A-Za-z0-9]{6}$') { throw 'Unexpected review-service Secret ARN.' }
        $reviewMetadata = (Invoke-EsoNative 'kubectl' ($exec + @('secretsmanager','describe-secret','--secret-id',$reviewArn,'--region','ap-northeast-2','--query','{ARN:ARN,KmsKeyId:KmsKeyId}','--output','json'))) -join "`n" | ConvertFrom-Json
        if ($reviewMetadata.ARN -ne $reviewArn -or $reviewMetadata.KmsKeyId) { throw 'Unexpected review-service Secret metadata.' }
        # The CLI selects only version metadata. The API key never leaves the Pod.
        $reviewVersion = (Invoke-EsoNative 'kubectl' ($exec + @('secretsmanager','get-secret-value','--secret-id',$reviewArn,'--version-stage','AWSCURRENT','--region','ap-northeast-2','--query','{ARN:ARN,VersionId:VersionId,VersionStages:VersionStages}','--output','json'))) -join "`n" | ConvertFrom-Json
        if ($reviewVersion.ARN -ne $reviewArn -or -not $reviewVersion.VersionId -or $reviewVersion.VersionStages -notcontains 'AWSCURRENT') { throw 'Review-service Secret read failed.' }
        Write-Output 'PASS: same ESO Pod Identity reads the current Claude Secret, with no API key output.'
        # Use a temporary ExternalSecret so the app owner's permanent resource
        # is not changed. ESO itself parses the JSON property in the cluster.
        $reviewSecret = @{apiVersion='external-secrets.io/v1';kind='ExternalSecret';metadata=@{name=$reviewName;namespace='platform'};spec=@{
            refreshInterval='1h';secretStoreRef=@{name='review-db';kind='SecretStore'}
            target=@{name=$reviewName;creationPolicy='Owner';deletionPolicy='Retain'}
            data=@(@{secretKey='ANTHROPIC_API_KEY';remoteRef=@{key=$reviewArn;property='ANTHROPIC_API_KEY'}})
        }}
        Write-EsoJson $reviewSecret $manifest
        $reviewAttempted = $true
        Invoke-EsoNative 'kubectl' ($base + @('apply','-f',$manifest))
        Invoke-EsoNative 'kubectl' ($target + @('wait','--for=condition=Ready',"externalsecret/$reviewName",'--timeout=180s'))
        $reviewKeyCount = (Invoke-EsoNative 'kubectl' ($target + @('get','secret',$reviewName,'-o','go-template={{len .data}}'))) -join ''
        $reviewOwner = (Invoke-EsoNative 'kubectl' ($target + @('get','secret',$reviewName,'-o','jsonpath={.metadata.ownerReferences[0].name}'))) -join ''
        if ($reviewKeyCount -ne '1' -or $reviewOwner -ne $reviewName) { throw 'Temporary Claude Secret keys or ownership differ.' }
        $reviewCommand = 'set -eu; test -s /review/ANTHROPIC_API_KEY; echo "PASS: workload consumes the synchronized Claude API key."'
        $reviewConsumer = @{apiVersion='v1';kind='Pod';metadata=@{name=$reviewConsumerName;namespace='platform'};spec=@{
            restartPolicy='Never';automountServiceAccountToken=$false;activeDeadlineSeconds=180
            containers=@(@{name='check';image='public.ecr.aws/docker/library/busybox:1.37.0';command=@('/bin/sh','-c',$reviewCommand)
                resources=@{requests=@{cpu='10m';memory='16Mi'};limits=@{cpu='100m';memory='32Mi'}}
                securityContext=@{runAsNonRoot=$true;runAsUser=1000;allowPrivilegeEscalation=$false;readOnlyRootFilesystem=$true;capabilities=@{drop=@('ALL')}}
                volumeMounts=@(@{name='review';mountPath='/review';readOnly=$true})})
            volumes=@(@{name='review';secret=@{secretName=$reviewName;defaultMode=292;items=@(@{key='ANTHROPIC_API_KEY';path='ANTHROPIC_API_KEY'})}})
        }}
        Write-EsoJson $reviewConsumer $manifest
        $reviewConsumerAttempted = $true
        Invoke-EsoNative 'kubectl' ($base + @('apply','-f',$manifest))
        Invoke-EsoNative 'kubectl' ($target + @('wait','--for=jsonpath={.status.phase}=Succeeded',"pod/$reviewConsumerName",'--timeout=180s'))
        $reviewLog = (Invoke-EsoNative 'kubectl' ($target + @('logs',$reviewConsumerName))) -join "`n"
        if ($reviewLog.Trim() -ne 'PASS: workload consumes the synchronized Claude API key.') { throw 'Claude Secret consumer did not return the expected success marker.' }
        Write-Output $reviewLog
    }
    $denied = 'if result=$(aws secretsmanager describe-secret --secret-id arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:eso-denied-test-123456 --region ap-northeast-2 2>&1); then exit 1; else case "$result" in *AccessDenied*) echo "PASS: other Secret access denied." ;; *) echo "Unexpected denial result"; exit 1 ;; esac; fi'
    Invoke-EsoNative 'kubectl' ($operator + @('exec',$identityName,'--','/bin/sh','-c',$denied))
    Write-Output 'PASS: real Pod Identity STS role and allowed Secret metadata read.'
    Write-EsoSyncManifest -SecretArn $outputs.secret_arn -Path $manifest
    Invoke-EsoNative 'kubectl' ($base + @('apply','--server-side','--dry-run=server','--field-manager=oneaction-eks-eso','-f',$manifest))
    Invoke-EsoNative 'kubectl' ($target + @('wait','--for=condition=Ready','secretstore/review-db','externalsecret/review-db','--timeout=180s'))
    $keyCount = (Invoke-EsoNative 'kubectl' ($target + @('get','secret','review-db-credentials','-o','go-template={{len .data}}'))) -join ''
    $owner = (Invoke-EsoNative 'kubectl' ($target + @('get','secret','review-db-credentials','-o','jsonpath={.metadata.ownerReferences[0].name}'))) -join ''
    if ($keyCount -ne '2' -or $owner -ne 'review-db') { throw 'Unexpected target Secret keys or ownership.' }
    $before = (Invoke-EsoNative 'kubectl' ($target + @('get','externalsecret','review-db','-o','json'))) -join "`n" | ConvertFrom-Json
    $syncToken = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
    Invoke-EsoNative 'kubectl' ($target + @('annotate','externalsecret','review-db',"force-sync=$syncToken",'--overwrite'))
    $timer = [Diagnostics.Stopwatch]::StartNew(); $refreshed = $false
    while ($timer.Elapsed.TotalSeconds -lt 180) {
        $after = (Invoke-EsoNative 'kubectl' ($target + @('get','externalsecret','review-db','-o','json'))) -join "`n" | ConvertFrom-Json
        if ($after.status.refreshTime -ne $before.status.refreshTime -and @($after.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1) { $refreshed = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $refreshed) { throw 'Forced Secret refresh did not complete.' }
    Write-Output 'PASS: actual ESO Secret synchronization and forced refresh, with no payload output.'
    $command = 'set -eu; test -s /db/username; test -s /db/password; test "$(cat /db/username)" = oneaction_admin; test "$(wc -c < /db/password)" -ge 8; echo "PASS: workload consumes the two synchronized Secret keys."'
    $consumer = @{apiVersion='v1';kind='Pod';metadata=@{name=$consumerName;namespace='platform'};spec=@{
        restartPolicy='Never';automountServiceAccountToken=$false;activeDeadlineSeconds=180
        containers=@(@{name='check';image='public.ecr.aws/docker/library/busybox:1.37.0';command=@('/bin/sh','-c',$command)
            resources=@{requests=@{cpu='10m';memory='16Mi'};limits=@{cpu='100m';memory='32Mi'}}
            securityContext=@{runAsNonRoot=$true;runAsUser=1000;allowPrivilegeEscalation=$false;readOnlyRootFilesystem=$true;capabilities=@{drop=@('ALL')}}
            volumeMounts=@(@{name='db';mountPath='/db';readOnly=$true})})
        volumes=@(@{name='db';secret=@{secretName='review-db-credentials';defaultMode=292;items=@(@{key='username';path='username'},@{key='password';path='password'})}})
    }}
    Write-EsoJson $consumer $manifest
    $consumerAttempted = $true
    Invoke-EsoNative 'kubectl' ($base + @('apply','-f',$manifest))
    Invoke-EsoNative 'kubectl' ($target + @('wait','--for=jsonpath={.status.phase}=Succeeded',"pod/$consumerName",'--timeout=180s'))
    $log = (Invoke-EsoNative 'kubectl' ($target + @('logs',$consumerName))) -join "`n"
    if ($log.Trim() -ne 'PASS: workload consumes the two synchronized Secret keys.') { throw 'Secret consumer did not return the expected success marker.' }
    Write-Output $log
    $versionsAfter = (Invoke-EsoNative 'aws' @('secretsmanager','describe-secret','--secret-id',$outputs.secret_arn,'--region','ap-northeast-2','--profile',$Profile,'--query','VersionIdsToStages','--output','json','--no-cli-pager')) -join "`n"
    if ($versionsBefore -ne $versionsAfter) { throw 'RDS Secret versions changed during testing; inspect rotation independently.' }
    # Check every auth/RBAC error during this run, rather than historical errors
    # from before the current policy had propagated.
    $logs = (Invoke-EsoNative 'kubectl' ($operator + @('logs','-l','app.kubernetes.io/instance=external-secrets','--all-containers=true',"--since-time=$verificationStart",'--tail=500','--max-log-requests=5'))) -join "`n"
    if ($logs -match 'AccessDenied|NoCredentialProviders|failed to refresh cached credentials|cannot list resource|cannot get resource') { throw 'ESO logs report an authentication or RBAC failure.' }
    Write-Output 'PASS: source Secret versions unchanged and no observed auth/RBAC errors.'
} finally {
    try {
        if ($reviewConsumerAttempted) { Invoke-EsoNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','platform','delete','pod',$reviewConsumerName,'--ignore-not-found','--wait=true','--timeout=60s')) }
    } finally {
        try {
            if ($reviewAttempted) {
                try { Invoke-EsoNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','platform','delete','externalsecret',$reviewName,'--ignore-not-found','--wait=true','--timeout=60s')) }
                finally { Invoke-EsoNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','platform','delete','secret',$reviewName,'--ignore-not-found','--wait=true','--timeout=60s')) }
            }
        } finally {
            try {
                if ($identityAttempted) { Invoke-EsoNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','external-secrets','delete','pod',$identityName,'--ignore-not-found','--wait=true','--timeout=60s')) }
            } finally {
                try { if ($consumerAttempted) { Invoke-EsoNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','platform','delete','pod',$consumerName,'--ignore-not-found','--wait=true','--timeout=60s')) } }
                finally { Remove-Item -LiteralPath $manifest, $kubeconfig }
            }
        }
    }
}
