[CmdletBinding()]
param(
    [string]$Profile = 'sbhackathon2026-team',
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$oneactionRegion = 'ap-northeast-2'
$oneactionNamespace = 'foundation-smoke-' + [guid]::NewGuid().ToString('N').Substring(0, 12)

function Invoke-CheckedNative {
    param([string]$Command, [string[]]$CommandArguments)
    $result = & $Command @CommandArguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE." }
    return $result
}

$identity = (Invoke-CheckedNative 'aws' @('sts', 'get-caller-identity', '--profile', $Profile, '--region', $oneactionRegion, '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
if ($identity.Account -ne '123456789012') { throw 'The AWS profile must use team account 123456789012.' }
$nodeGroup = (Invoke-CheckedNative 'aws' @('eks', 'describe-nodegroup', '--cluster-name', 'oneaction', '--nodegroup-name', 'oneaction-general', '--profile', $Profile, '--region', $oneactionRegion, '--query', 'nodegroup', '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
if ($nodeGroup.status -ne 'ACTIVE') { throw 'Run the Ready checks before the networking smoke test.' }

$oneactionKubeconfig = [IO.Path]::GetTempFileName()
$oneactionManifest = [IO.Path]::GetTempFileName()
$oneactionNamespaceCreated = $false
try {
    Invoke-CheckedNative 'aws' @('eks', 'update-kubeconfig', '--name', 'oneaction', '--profile', $Profile, '--region', $oneactionRegion, '--kubeconfig', $oneactionKubeconfig) | Out-Null
    $oneactionKubectlBase = @('--kubeconfig', $oneactionKubeconfig)
    Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('create', 'namespace', $oneactionNamespace))
    $oneactionNamespaceCreated = $true

    # Image and nslookup procedure: Kubernetes' official DNS debugging guide.
    # A DaemonSet checks Pod networking and Service DNS on each general node.
    $daemonSet = @{
        apiVersion = 'apps/v1'; kind = 'DaemonSet'
        metadata = @{ name = 'dns-smoke'; namespace = $oneactionNamespace }
        spec = @{
            selector = @{ matchLabels = @{ app = 'foundation-dns-smoke' } }
            template = @{
                metadata = @{ labels = @{ app = 'foundation-dns-smoke' } }
                spec = @{
                    nodeSelector = @{ 'eks.amazonaws.com/nodegroup' = 'oneaction-general' }
                    automountServiceAccountToken = $false
                    terminationGracePeriodSeconds = 0
                    containers = @(@{
                        name = 'dnsutils'; image = 'registry.k8s.io/e2e-test-images/agnhost:2.39'
                        imagePullPolicy = 'IfNotPresent'
                        resources = @{ requests = @{ cpu = '10m'; memory = '32Mi' }; limits = @{ cpu = '100m'; memory = '128Mi' } }
                    })
                }
            }
        }
    }
    [IO.File]::WriteAllText($oneactionManifest, (ConvertTo-Json -InputObject $daemonSet -Depth 12), [Text.UTF8Encoding]::new($false))
    Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('apply', '-f', $oneactionManifest))
    Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('rollout', 'status', 'daemonset/dns-smoke', '--namespace', $oneactionNamespace, "--timeout=${TimeoutSeconds}s"))
    $pods = (Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('get', 'pods', '--namespace', $oneactionNamespace, '--selector=app=foundation-dns-smoke', '--output=json'))) -join "`n" | ConvertFrom-Json
    $nodeNames = @($pods.items | ForEach-Object { $_.spec.nodeName } | Sort-Object -Unique)
    if ($nodeNames.Count -lt $nodeGroup.scalingConfig.desiredSize) { throw 'Smoke Pods do not cover the desired node count.' }
    foreach ($pod in $pods.items) {
        Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('exec', '--namespace', $oneactionNamespace, $pod.metadata.name, '--', 'nslookup', 'kubernetes.default.svc.cluster.local'))
        Write-Output "PASS: Pod IP $($pod.status.podIP) and Kubernetes Service DNS on node $($pod.spec.nodeName)."
    }
    Write-Output "PASS: Pod networking and Service DNS on $($nodeNames.Count) nodes."
} finally {
    try {
        if ($oneactionNamespaceCreated) {
            Invoke-CheckedNative 'kubectl' ($oneactionKubectlBase + @('delete', 'namespace', $oneactionNamespace, '--wait=true', '--timeout=60s'))
        }
    } finally {
        foreach ($path in @($oneactionKubeconfig, $oneactionManifest)) {
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
    }
}
