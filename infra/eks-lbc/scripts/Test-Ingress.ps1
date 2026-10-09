[CmdletBinding()]
param([string]$Profile = 'sbhackathon2026-team')

# Read-only acceptance test for the existing GitOps sample-app Ingress.
# Does not create/update Kubernetes objects or AWS resources.
. "$PSScriptRoot/Common.ps1"
$outputs = Get-LbcOutputs
$kubeconfig = New-LbcKubeconfig -Profile $Profile
try {
    $base = @('--kubeconfig', $kubeconfig, '--request-timeout=30s')
    $app = $base + @('-n', 'sample-app')
    Invoke-LbcNative 'kubectl' ($app + @('wait', 'ingress/sample-app', '--for=jsonpath={.status.loadBalancer.ingress[0].hostname}', '--timeout=600s'))
    $ingress = (Invoke-LbcNative 'kubectl' ($app + @('get', 'ingress', 'sample-app', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if ($ingress.spec.ingressClassName -ne 'alb' -or $ingress.metadata.annotations.'alb.ingress.kubernetes.io/target-type' -ne 'ip') { throw 'Expected the reviewed ALB/IP Ingress.' }
    $hostname = $ingress.status.loadBalancer.ingress[0].hostname
    $awsBase = @('--region', $outputs.aws_region, '--profile', $Profile, '--output', 'json', '--no-cli-pager')
    $lbs = (Invoke-LbcNative 'aws' (@('elbv2', 'describe-load-balancers') + $awsBase)) -join "`n" | ConvertFrom-Json
    $lb = @($lbs.LoadBalancers | Where-Object DNSName -eq $hostname)
    if ($lb.Count -ne 1 -or $lb[0].VpcId -ne $outputs.vpc_id -or $lb[0].Scheme -ne 'internet-facing' -or $lb[0].Type -ne 'application') { throw 'Ingress ALB differs from the reviewed VPC/scheme/type.' }
    $lb = $lb[0]
    Invoke-LbcNative 'aws' (@('elbv2', 'wait', 'load-balancer-available', '--load-balancer-arns', $lb.LoadBalancerArn) + $awsBase)
    $bindings = (Invoke-LbcNative 'kubectl' ($app + @('get', 'targetgroupbindings', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    $binding = @($bindings.items | Where-Object { $_.spec.serviceRef.name -eq 'sample-app' -and $_.spec.serviceRef.port -eq 80 })
    if ($binding.Count -ne 1 -or $binding[0].spec.targetType -ne 'ip') { throw 'Expected one sample-app IP TargetGroupBinding.' }
    $tgArn = $binding[0].spec.targetGroupARN
    $tg = (Invoke-LbcNative 'aws' (@('elbv2', 'describe-target-groups', '--target-group-arns', $tgArn) + $awsBase)) -join "`n" | ConvertFrom-Json
    if ($tg.TargetGroups[0].VpcId -ne $outputs.vpc_id -or $tg.TargetGroups[0].LoadBalancerArns -notcontains $lb.LoadBalancerArn -or $tg.TargetGroups[0].HealthCheckPath -ne '/healthz') { throw 'Target group is not attached to the expected ALB/health check.' }
    $pods = (Invoke-LbcNative 'kubectl' ($app + @('get', 'pods', '-l', 'app=sample-app', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    $readyPods = @($pods.items | Where-Object { -not $_.metadata.deletionTimestamp -and @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -eq 1 })
    if ($readyPods.Count -ne 2) { throw 'Expected two Ready sample-app Pods.' }
    $expectedIps = @($readyPods.status.podIP | Sort-Object)
    $healthy = $false
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $health = (Invoke-LbcNative 'aws' (@('elbv2', 'describe-target-health', '--target-group-arn', $tgArn) + $awsBase)) -join "`n" | ConvertFrom-Json
        $targets = @($health.TargetHealthDescriptions)
        $targetIps = @($targets.Target.Id | Sort-Object)
        if ($targets.Count -eq 2 -and @($targets | Where-Object { $_.TargetHealth.State -ne 'healthy' }).Count -eq 0 -and ($expectedIps -join ',') -eq ($targetIps -join ',')) { $healthy = $true; break }
        if ($attempt -lt 18) { Write-Output "Waiting for two Healthy targets ($attempt/18)."; Start-Sleep -Seconds 20 }
    }
    if (-not $healthy) { throw 'Target health or Pod IP correspondence failed.' }
    $sg = (Invoke-LbcNative 'aws' (@('ec2', 'describe-security-groups', '--group-ids') + $lb.SecurityGroups + $awsBase)) -join "`n" | ConvertFrom-Json
    if (@($sg.SecurityGroups | Where-Object { $_.VpcId -ne $outputs.vpc_id }).Count -gt 0) { throw 'ALB security group is outside the team VPC.' }
    $url = "http://$hostname"
    $healthResponse = Invoke-WebRequest -UseBasicParsing -Uri "$url/healthz" -TimeoutSec 30
    $infoResponse = Invoke-WebRequest -UseBasicParsing -Uri "$url/api/info" -TimeoutSec 30
    $pageResponse = Invoke-WebRequest -UseBasicParsing -Uri "$url/" -TimeoutSec 30
    $info = $infoResponse.Content | ConvertFrom-Json
    if ($healthResponse.StatusCode -ne 200 -or $infoResponse.StatusCode -ne 200 -or $pageResponse.StatusCode -ne 200 -or $info.environment -ne 'aws' -or $info.region -ne 'ap-northeast-2') { throw 'External app response failed.' }
    $rollout = (Invoke-LbcNative 'kubectl' ($app + @('get', 'rollout', 'sample-app', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    $application = (Invoke-LbcNative 'kubectl' ($base + @('-n', 'argocd', 'get', 'application', 'sample-app-aws', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if ($rollout.status.phase -ne 'Healthy' -or $application.status.sync.status -ne 'Synced' -or $application.status.health.status -ne 'Healthy') { throw 'GitOps Application or Rollout is not healthy.' }
    $nodes = (Invoke-LbcNative 'kubectl' ($base + @('get', 'nodes', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if ($nodes.items.Count -ne 2 -or @($nodes.items | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -ne 1 }).Count -gt 0) { throw 'EKS nodes are not both Ready.' }
    $deployments = (Invoke-LbcNative 'kubectl' ($base + @('get', 'deployments', '-A', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    foreach ($name in @('aws-load-balancer-controller', 'external-secrets', 'external-secrets-cert-controller', 'external-secrets-webhook')) {
        $deployment = @($deployments.items | Where-Object { $_.metadata.name -eq $name -and $_.metadata.namespace -in @('kube-system', 'external-secrets') })
        if ($deployment.Count -ne 1 -or $deployment[0].status.readyReplicas -ne $deployment[0].spec.replicas) { throw "Deployment is not Ready: $name" }
    }
    $secret = (Invoke-LbcNative 'kubectl' ($base + @('-n', 'platform', 'get', 'externalsecret', 'review-db', '-o', 'json'))) -join "`n" | ConvertFrom-Json
    if (@($secret.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -ne 1) { throw 'Existing RDS ExternalSecret is not Ready.' }
    Write-Output 'PASS: Ingress ALB active in the team VPC, two targets Healthy and matching Ready Pod IPs.'
    Write-Output 'PASS: external /, /healthz and /api/info HTTP 200; environment=aws, region=ap-northeast-2.'
    Write-Output 'PASS: two EKS nodes Ready, LBC/ESO deployments Ready, RDS ExternalSecret Ready.'
    Write-Output 'PASS: Argo CD Application Synced/Healthy and sample-app Rollout Healthy.'
    Write-Output ("URL: $url")
    Write-Output ("ALB: " + $lb.LoadBalancerArn)
    Write-Output ("TARGET_GROUP: $tgArn")
    Write-Output ("INFO: " + ($info | ConvertTo-Json -Compress))
    Write-Output ("GITOPS_REVISION: " + $application.status.sync.revision)
    Write-Output ("ROLLOUT_IMAGE: " + $rollout.spec.template.spec.containers[0].image)
} finally {
    Remove-Item -LiteralPath $kubeconfig
}
