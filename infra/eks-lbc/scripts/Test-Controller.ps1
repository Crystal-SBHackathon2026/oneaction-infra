[CmdletBinding()]
param([string]$Profile = 'sbhackathon2026-team', [string]$HelmCommand = 'helm')
. "$PSScriptRoot/Common.ps1"
$outputs = Get-LbcOutputs
$kubeconfig = New-LbcKubeconfig -Profile $Profile
$manifest = [IO.Path]::GetTempFileName()
$suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
$podName = "lbc-identity-$suffix"
$serviceName = "lbc-admission-$suffix"
$createdPod = $false; $createdService = $false
try {
    $base = @('--kubeconfig', $kubeconfig)
    $ns = $base + @('-n', 'kube-system')
    $release = (Invoke-LbcNative $HelmCommand (@('list', '-n', 'kube-system', '-o', 'json') + $base)) -join "`n" | ConvertFrom-Json
    if (@($release | Where-Object { $_.name -eq 'aws-load-balancer-controller' -and $_.chart -eq 'aws-load-balancer-controller-3.6.0' -and $_.status -eq 'deployed' }).Count -ne 1) { throw 'Expected the pinned deployed Helm release.' }
    Invoke-LbcNative 'kubectl' ($ns + @('rollout', 'status', 'deployment/aws-load-balancer-controller', '--timeout=300s'))
    $deployment = (Invoke-LbcNative 'kubectl' ($ns + @('get', 'deployment', 'aws-load-balancer-controller', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if ($deployment.spec.replicas -ne 2 -or $deployment.status.readyReplicas -ne 2 -or $deployment.spec.template.spec.containers[0].image -notlike '*:v3.6.0') { throw 'Controller replicas or image differ from the reviewed configuration.' }
    $sa = (Invoke-LbcNative 'kubectl' ($ns + @('get', 'serviceaccount', 'aws-load-balancer-controller', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if ($sa.metadata.annotations.'eks.amazonaws.com/role-arn' -ne $outputs.role_arn) { throw 'ServiceAccount does not use the dedicated IAM role.' }
    Invoke-LbcNative 'kubectl' ($base + @('wait', '--for=condition=Established', 'crd/targetgroupbindings.elbv2.k8s.aws', '--timeout=60s'))
    $tg = (Invoke-LbcNative 'aws' @('elbv2', 'describe-target-groups', '--names', 'platform-tg', '--region', 'ap-northeast-2', '--profile', $Profile, '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
    if ($tg.TargetGroups.Count -ne 1 -or $tg.TargetGroups[0].TargetType -ne 'ip' -or $tg.TargetGroups[0].Port -ne 8080 -or $tg.TargetGroups[0].VpcId -ne $outputs.vpc_id) { throw 'Existing platform target group differs from the handoff.' }
    $arn = $tg.TargetGroups[0].TargetGroupArn
    $beforeTargets = (Invoke-LbcNative 'aws' @('elbv2', 'describe-target-health', '--target-group-arn', $arn, '--region', 'ap-northeast-2', '--profile', $Profile, '--query', 'TargetHealthDescriptions[].Target', '--output', 'json', '--no-cli-pager')) -join "`n"
    $beforeAlbs = (Invoke-LbcNative 'aws' @('elbv2', 'describe-load-balancers', '--region', 'ap-northeast-2', '--profile', $Profile, '--query', 'LoadBalancers[].LoadBalancerArn', '--output', 'json', '--no-cli-pager')) -join "`n"
    $pod = @{ apiVersion = 'v1'; kind = 'Pod'; metadata = @{name=$podName; namespace='kube-system'}; spec = @{
        serviceAccountName='aws-load-balancer-controller'; restartPolicy='Never'
        containers=@(@{ name='aws'; image='public.ecr.aws/aws-cli/aws-cli:2.37.10'; command=@('/bin/sh','-c','sleep 300'); resources=@{requests=@{cpu='25m';memory='64Mi'};limits=@{cpu='250m';memory='256Mi'}} })
    } }
    Write-LbcJson $pod $manifest
    Invoke-LbcNative 'kubectl' ($base + @('apply', '-f', $manifest))
    $createdPod = $true
    Invoke-LbcNative 'kubectl' ($ns + @('wait', '--for=condition=Ready', "pod/$podName", '--timeout=180s'))
    $exec = $ns + @('exec', $podName, '--', 'aws')
    $identity = (Invoke-LbcNative 'kubectl' ($exec + @('sts', 'get-caller-identity', '--region', 'ap-northeast-2', '--output', 'json'))) -join "`n" | ConvertFrom-Json
    if ($identity.Account -ne '123456789012' -or $identity.Arn -notlike 'arn:aws:sts::123456789012:assumed-role/oneaction-aws-load-balancer-controller/*') { throw 'The Pod did not assume the dedicated controller role.' }
    $podTg = (Invoke-LbcNative 'kubectl' ($exec + @('elbv2', 'describe-target-groups', '--target-group-arns', $arn, '--region', 'ap-northeast-2', '--output', 'json'))) -join "`n" | ConvertFrom-Json
    if ($podTg.TargetGroups[0].VpcId -ne $outputs.vpc_id) { throw 'Pod target-group read failed.' }
    Invoke-LbcNative 'kubectl' ($exec + @('elbv2', 'describe-target-health', '--target-group-arn', $arn, '--region', 'ap-northeast-2', '--query', 'length(TargetHealthDescriptions)', '--output', 'text'))
    Write-Output 'PASS: dedicated Pod IRSA identity and real ELB read calls.'
    $service = @{apiVersion='v1';kind='Service';metadata=@{name=$serviceName;namespace='kube-system'};spec=@{type='ClusterIP';ports=@(@{port=80;targetPort=8080})}}
    Write-LbcJson $service $manifest
    Invoke-LbcNative 'kubectl' ($base + @('apply', '-f', $manifest))
    $createdService = $true
    # Omit targetType/vpcID: the real mutating webhook must discover them via AWS.
    $binding = @{apiVersion='elbv2.k8s.aws/v1beta1';kind='TargetGroupBinding';metadata=@{name=$serviceName;namespace='kube-system'};spec=@{targetGroupARN=$arn;serviceRef=@{name=$serviceName;port=80}}}
    Write-LbcJson $binding $manifest
    $admitted = (Invoke-LbcNative 'kubectl' ($base + @('apply', '--dry-run=server', '-f', $manifest, '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if ($admitted.spec.targetType -ne 'ip' -or $admitted.spec.vpcID -ne $outputs.vpc_id) { throw 'Webhook did not discover the target group properties.' }
    Write-Output 'PASS: real TargetGroupBinding admission, TLS and AWS discovery (server dry-run only).'
    $bindings = (Invoke-LbcNative 'kubectl' ($ns + @('get', 'targetgroupbindings', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if (@($bindings.items | Where-Object { $_.metadata.name -eq $serviceName }).Count -gt 0) { throw 'Dry-run unexpectedly persisted a binding.' }
    $logs = (Invoke-LbcNative 'kubectl' ($ns + @('logs', '-l', 'app.kubernetes.io/name=aws-load-balancer-controller', '--all-containers=true', '--since=10m', '--tail=500'))) -join "`n"
    if ($logs -match 'AccessDenied|WebIdentityErr|NoCredentialProviders|failed to refresh cached credentials|Reconciler error') { throw 'Controller logs report an AWS authentication or reconciliation failure.' }
    $afterTargets = (Invoke-LbcNative 'aws' @('elbv2', 'describe-target-health', '--target-group-arn', $arn, '--region', 'ap-northeast-2', '--profile', $Profile, '--query', 'TargetHealthDescriptions[].Target', '--output', 'json', '--no-cli-pager')) -join "`n"
    $afterAlbs = (Invoke-LbcNative 'aws' @('elbv2', 'describe-load-balancers', '--region', 'ap-northeast-2', '--profile', $Profile, '--query', 'LoadBalancers[].LoadBalancerArn', '--output', 'json', '--no-cli-pager')) -join "`n"
    if ($beforeTargets -ne $afterTargets -or $beforeAlbs -ne $afterAlbs) { throw 'Existing targets or load balancers changed during the read-only smoke test.' }
    Write-Output 'PASS: controller 2/2 Ready, no auth errors, no target or load-balancer changes.'
} finally {
    try {
        if ($createdPod) { Invoke-LbcNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','kube-system','delete','pod',$podName,'--wait=true','--timeout=60s')) }
    } finally {
        try { if ($createdService) { Invoke-LbcNative 'kubectl' (@('--kubeconfig',$kubeconfig,'-n','kube-system','delete','service',$serviceName,'--wait=true','--timeout=30s')) } }
        finally { Remove-Item -LiteralPath $manifest, $kubeconfig }
    }
}
