[CmdletBinding()]
param([string]$Profile = 'sbhackathon2026-team', [string]$HelmCommand = 'helm', [string]$PythonCommand = 'python', [Parameter(Mandatory)][string]$ArtifactDirectory, [switch]$CheckRetain, [switch]$CheckPopulate)
. "$PSScriptRoot/Notifications.Common.ps1"
$outputs = Get-NotificationsOutputs
$manifests = Get-NotificationsManifests -Directory $ArtifactDirectory -PythonCommand $PythonCommand
$kubeconfig = New-EsoKubeconfig -Profile $Profile
$start = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$identityName = 'notifications-identity-' + [guid]::NewGuid().ToString('N').Substring(0,10)
$identityPath = [IO.Path]::GetTempFileName()
$identityAttempted = $false
try {
    $base = @('--kubeconfig',$kubeconfig)
    foreach ($name in @('external-secrets','external-secrets-webhook','external-secrets-cert-controller','external-secrets-argocd')) {
        Invoke-EsoNative 'kubectl' ($base + @('-n','external-secrets','rollout','status',"deployment/$name",'--timeout=180s')) | Out-Host
    }
    $deployment = Read-NotificationsKubeJson $kubeconfig @('-n','external-secrets','get','deployment','external-secrets-argocd','-o','json')
    $podSpec = $deployment.spec.template.spec
    if ($deployment.status.readyReplicas -ne 1 -or $podSpec.serviceAccountName -ne 'external-secrets-argocd' -or $podSpec.containers[0].args -notcontains '--namespace=argocd' -or $podSpec.containers[0].image -ne 'ghcr.io/external-secrets/external-secrets:v2.12.0') { throw 'Unexpected Notifications controller configuration.' }
    $sa = Read-NotificationsKubeJson $kubeconfig @('-n','external-secrets','get','serviceaccount','external-secrets-argocd','-o','json')
    if ($sa.metadata.annotations.'eks.amazonaws.com/role-arn') { throw 'Do not mix Pod Identity and IRSA.' }
    $identityPod = @{apiVersion='v1';kind='Pod';metadata=@{name=$identityName;namespace='external-secrets'};spec=@{
        serviceAccountName='external-secrets-argocd';restartPolicy='Never';activeDeadlineSeconds=600
        containers=@(@{name='aws';image='public.ecr.aws/aws-cli/aws-cli:2.37.10';command=@('/bin/sh','-c','sleep 600')
            resources=@{requests=@{cpu='25m';memory='64Mi'};limits=@{cpu='250m';memory='256Mi'}}
            securityContext=@{allowPrivilegeEscalation=$false;capabilities=@{drop=@('ALL')}}})
    }}
    Write-EsoJson $identityPod $identityPath
    $identityAttempted = $true
    Invoke-EsoNative 'kubectl' ($base + @('apply','-f',$identityPath)) | Out-Host
    Invoke-EsoNative 'kubectl' ($base + @('-n','external-secrets','wait','--for=condition=Ready',"pod/$identityName",'--timeout=180s')) | Out-Host
    $exec = $base + @('-n','external-secrets','exec',$identityName,'--')
    $identity = (Invoke-EsoNative 'kubectl' ($exec + @('aws','sts','get-caller-identity','--region','ap-northeast-2','--output','json'))) -join "`n" | ConvertFrom-Json
    if ($identity.Account -ne '123456789012' -or $identity.Arn -notlike 'arn:aws:sts::123456789012:assumed-role/oneaction-external-secrets-argocd/*') { throw 'Test Pod did not use the dedicated Notifications role.' }
    $version = (Invoke-EsoNative 'kubectl' ($exec + @('aws','secretsmanager','get-secret-value','--secret-id',$outputs.review_service_secret_arn,'--region','ap-northeast-2','--query','{ARN:ARN,VersionId:VersionId}','--output','json'))) -join "`n" | ConvertFrom-Json
    if ($version.ARN -ne $outputs.review_service_secret_arn -or -not $version.VersionId) { throw 'Notifications source read failed.' }
    foreach ($deniedArn in @($outputs.secret_arn,$outputs.gitops_token_secret_arn)) {
        if (-not $deniedArn) { continue }
        if ($deniedArn -notmatch '^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:[A-Za-z0-9/_+=.@!-]+-[A-Za-z0-9]{6}$') { throw 'Unexpected denial-test Secret ARN.' }
        $deniedCommand = 'if result=$(aws secretsmanager describe-secret --secret-id "$1" --region ap-northeast-2 2>&1); then exit 1; else case "$result" in *AccessDenied*) echo "PASS: out-of-scope Secret access denied." ;; *) echo "Unexpected denial result"; exit 1 ;; esac; fi'
        Invoke-EsoNative 'kubectl' ($exec + @('/bin/sh','-c',$deniedCommand,'check',$deniedArn)) | Out-Host
    }
    Write-Output 'PASS: actual Pod Identity role and source read verified; RDS/GitOps Secret metadata access denied.'
    foreach ($verb in @('get','list','create','update','patch','delete')) {
        foreach ($namespace in @('argocd','platform','default','kube-system','external-secrets')) {
            $answer = & kubectl @base --request-timeout=30s auth can-i $verb secrets '--as=system:serviceaccount:external-secrets:external-secrets-argocd' -n $namespace
            $expected = if ($namespace -eq 'argocd') { 'yes' } else { 'no' }
            if (($answer -join '').Trim() -ne $expected) { throw "Unexpected Notifications Secret RBAC: $verb/$namespace." }
        }
    }
    Write-Output 'PASS: actual Secret read/write RBAC is limited to argocd.'
    $before = Read-NotificationsKubeJson $kubeconfig @('-n','argocd','get','secret','argocd-notifications-secret','-o','json')
    Wait-NotificationsRefresh $kubeconfig 'argocd' 'argocd-notifications'
    $after = Read-NotificationsKubeJson $kubeconfig @('-n','argocd','get','secret','argocd-notifications-secret','-o','json')
    Assert-NotificationsSecretPreserved $before $after
    Write-Output 'PASS: forced token refresh preserves the working token, all existing keys and labels.'
    if ($CheckPopulate) {
        Test-NotificationsMergePopulate -Kubeconfig $kubeconfig -ExpectedToken $before.data.ARGOCD_WEBHOOK_TOKEN
        $after = Read-NotificationsKubeJson $kubeconfig @('-n','argocd','get','secret','argocd-notifications-secret','-o','json')
        Assert-NotificationsSecretPreserved $before $after
        Write-Output 'PASS: production Notifications token and Secret remain unchanged after the isolated population test.'
    }
    if ($CheckRetain) {
        try {
            Invoke-EsoNative 'kubectl' ($base + @('-n','argocd','delete','externalsecret','argocd-notifications','--wait=true','--timeout=60s')) | Out-Host
            $retained = Read-NotificationsKubeJson $kubeconfig @('-n','argocd','get','secret','argocd-notifications-secret','-o','json')
            Assert-NotificationsSecretPreserved $before $retained
            Write-Output 'PASS: removing the Merge ExternalSecret retains the existing Notifications token/Secret.'
        } finally {
            Invoke-EsoNative 'kubectl' ($base + @('apply','--server-side','--field-manager=oneaction-notifications-eso','-f',$manifests[1])) | Out-Host
            Invoke-EsoNative 'kubectl' ($base + @('-n','argocd','wait','--for=condition=Ready','externalsecret/argocd-notifications','--timeout=180s')) | Out-Host
        }
    }
    foreach ($name in @('review-db','review-service-secrets')) { Wait-NotificationsRefresh $kubeconfig 'platform' $name }
    Write-Output 'PASS: existing platform DB/app Secret synchronization and forced refresh remain healthy.'
    $logs = (Invoke-EsoNative 'kubectl' ($base + @('-n','external-secrets','logs','deployment/external-secrets-argocd',"--since-time=$start",'--tail=300'))) -join "`n"
    if ($logs -match 'AccessDenied|NoCredentialProviders|failed to refresh cached credentials|cannot list resource|cannot get resource|error processing spec.data') { throw 'Notifications ESO reports auth/RBAC/sync errors.' }
    # Follow controllers rather than retaining a snapshot of Pods which another
    # team's concurrent deployment can replace while kubectl wait is running.
    $platformDeployments = Read-NotificationsKubeJson $kubeconfig @('-n','platform','get','deployments','-o','json')
    if ($platformDeployments.items.Count -lt 2) { throw 'Expected the existing platform deployments.' }
    foreach ($item in $platformDeployments.items) {
        Invoke-EsoNative 'kubectl' ($base + @('-n','platform','rollout','status',"deployment/$($item.metadata.name)",'--timeout=180s')) | Out-Host
    }
    $rolloutTimer = [Diagnostics.Stopwatch]::StartNew()
    $sampleReady = $false
    while ($rolloutTimer.Elapsed.TotalSeconds -lt 180) {
        $rollout = Read-NotificationsKubeJson $kubeconfig @('-n','sample-app','get','rollout','sample-app','-o','json')
        if ($rollout.status.phase -eq 'Healthy' -and $rollout.status.readyReplicas -ge $rollout.spec.replicas -and $rollout.status.updatedReplicas -eq $rollout.spec.replicas) { $sampleReady = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $sampleReady) { throw 'Sample app rollout did not become Healthy/Ready.' }
    $ingresses = Read-NotificationsKubeJson $kubeconfig @('-n','sample-app','get','ingress','-o','json')
    $hosts = @($ingresses.items | ForEach-Object { $_.status.loadBalancer.ingress } | ForEach-Object { $_.hostname } | Where-Object { $_ })
    if ($hosts.Count -ne 1 -or $hosts[0] -notmatch '^[a-z0-9-]+\.ap-northeast-2\.elb\.amazonaws\.com$') { throw 'Expected a single sample-app ALB in Seoul.' }
    foreach ($url in @("http://$($hosts[0])/healthz",'http://oneaction-alb-0000000000.ap-northeast-2.elb.amazonaws.com/healthz')) {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 20
        if ([int]$response.StatusCode -ne 200) { throw 'A service health endpoint did not return 200.' }
    }
    $info = Invoke-WebRequest -UseBasicParsing -Uri "http://$($hosts[0])/api/info" -TimeoutSec 20
    $app = $info.Content | ConvertFrom-Json
    if ([int]$info.StatusCode -ne 200 -or $app.environment -ne 'aws' -or $app.region -ne 'ap-northeast-2') { throw 'Sample app environment check failed.' }
    Write-Output 'PASS: platform/sample-app Pods Ready; both public health endpoints 200 and sample-app AWS region verified.'
    Write-Output 'PASS: no observed Notifications ESO auth/RBAC/sync errors during forced refresh.'
} finally {
    $before = $null; $after = $null; $retained = $null
    try {
        if ($identityAttempted) { Invoke-EsoNative 'kubectl' @('--kubeconfig',$kubeconfig,'-n','external-secrets','delete','pod',$identityName,'--ignore-not-found','--wait=true','--timeout=60s') | Out-Host }
    } finally { Remove-Item -LiteralPath $kubeconfig,$identityPath -ErrorAction SilentlyContinue }
}
