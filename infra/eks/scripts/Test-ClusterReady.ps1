[CmdletBinding()]
param(
    [string]$Profile = 'sbhackathon2026-team',
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$oneactionRegion = 'ap-northeast-2'
$oneactionClusterName = 'oneaction'

function Invoke-CheckedNative {
    param([string]$Command, [string[]]$CommandArguments)
    $result = & $Command @CommandArguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
    return $result
}

$identity = (Invoke-CheckedNative 'aws' @('sts', 'get-caller-identity', '--profile', $Profile, '--region', $oneactionRegion, '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
if ($identity.Account -ne '123456789012') { throw 'The AWS profile must use team account 123456789012.' }
$cluster = (Invoke-CheckedNative 'aws' @('eks', 'describe-cluster', '--name', $oneactionClusterName, '--profile', $Profile, '--region', $oneactionRegion, '--query', 'cluster', '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
if ($cluster.status -ne 'ACTIVE') { throw "Cluster status is $($cluster.status)." }
$nodeGroup = (Invoke-CheckedNative 'aws' @('eks', 'describe-nodegroup', '--cluster-name', $oneactionClusterName, '--nodegroup-name', 'oneaction-general', '--profile', $Profile, '--region', $oneactionRegion, '--query', 'nodegroup', '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
if ($nodeGroup.status -ne 'ACTIVE') { throw "Node group status is $($nodeGroup.status)." }
if (@($nodeGroup.health.issues).Count -gt 0) { throw 'EKS reports node group health issues.' }
$client = (Invoke-CheckedNative 'kubectl' @('version', '--client', '--output=json')) -join "`n" | ConvertFrom-Json
if ([math]::Abs([int]($client.clientVersion.minor -replace '\D', '') - [int]($cluster.version -split '\.')[1]) -gt 1) {
    throw 'kubectl must be within one minor version of the cluster.'
}

# Keep the operator's default kubeconfig and current context untouched.
$oneactionKubeconfig = [System.IO.Path]::GetTempFileName()
try {
    Invoke-CheckedNative 'aws' @('eks', 'update-kubeconfig', '--name', $oneactionClusterName, '--profile', $Profile, '--region', $oneactionRegion, '--kubeconfig', $oneactionKubeconfig) | Out-Null
    $oneactionKubectlBase = @('--kubeconfig', $oneactionKubeconfig)
    Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('wait', '--for=condition=Ready', 'nodes', '--selector=eks.amazonaws.com/nodegroup=oneaction-general', "--timeout=${TimeoutSeconds}s"))
    $nodes = (Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('get', 'nodes', '--selector=eks.amazonaws.com/nodegroup=oneaction-general', '--output=json'))) -join "`n" | ConvertFrom-Json
    if (@($nodes.items).Count -lt $nodeGroup.scalingConfig.desiredSize) { throw 'Fewer nodes joined than the desired node count.' }
    foreach ($node in $nodes.items) {
        if (@($node.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -ne 1) {
            throw "Node $($node.metadata.name) is not Ready."
        }
    }
    foreach ($addonName in @('vpc-cni', 'kube-proxy', 'coredns', 'eks-pod-identity-agent')) {
        $addon = (Invoke-CheckedNative 'aws' @('eks', 'describe-addon', '--cluster-name', $oneactionClusterName, '--addon-name', $addonName, '--profile', $Profile, '--region', $oneactionRegion, '--query', 'addon', '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
        if ($addon.status -ne 'ACTIVE' -or @($addon.health.issues).Count -gt 0) { throw "Add-on $addonName is not healthy." }
    }
    $instanceIds = @($nodes.items | ForEach-Object { ($_.spec.providerID -split '/')[-1] })
    if (@($instanceIds | Where-Object { $_ -notmatch '^i-[a-f0-9]+$' }).Count -gt 0) { throw 'Unexpected EC2 provider ID on an EKS node.' }
    $creditArguments = @('ec2', 'describe-instance-credit-specifications', '--instance-ids') + $instanceIds + @('--profile', $Profile, '--region', $oneactionRegion, '--output', 'json', '--no-cli-pager')
    $credits = (Invoke-CheckedNative 'aws' $creditArguments) -join "`n" | ConvertFrom-Json
    if (@($credits.InstanceCreditSpecifications).Count -ne $instanceIds.Count -or @($credits.InstanceCreditSpecifications | Where-Object { $_.CpuCredits -ne 'standard' }).Count -gt 0) {
        throw 'Node CPU credits must actually be standard; a launch-template plan alone is insufficient.'
    }
    foreach ($workload in @('daemonset/aws-node', 'daemonset/kube-proxy', 'daemonset/eks-pod-identity-agent', 'deployment/coredns')) {
        Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('rollout', 'status', $workload, '--namespace=kube-system', "--timeout=${TimeoutSeconds}s"))
    }
    Write-Output "PASS: $(@($nodes.items).Count) Ready nodes with standard CPU credits and all four foundation add-ons are healthy."
} finally {
    if (Test-Path -LiteralPath $oneactionKubeconfig) {
        Remove-Item -LiteralPath $oneactionKubeconfig
    }
}
