[CmdletBinding()]
param(
    [string]$Profile = 'sbhackathon2026-team',
    [string]$HelmCommand = 'helm',
    [Parameter(Mandatory)][string]$ArtifactDirectory
)
. "$PSScriptRoot/Common.ps1"
$outputs = Get-LbcOutputs
$chart = Get-LbcChart -HelmCommand $HelmCommand -Directory $ArtifactDirectory
$kubeconfig = New-LbcKubeconfig -Profile $Profile
$runtime = [IO.Path]::GetTempFileName()
try {
    $base = @('--kubeconfig', $kubeconfig)
    $existing = (Invoke-LbcNative $HelmCommand (@('list', '-n', 'kube-system', '-o', 'json') + $base)) -join "`n" | ConvertFrom-Json
    $release = @($existing | Where-Object name -EQ 'aws-load-balancer-controller')
    if ($release.Count -eq 0) {
        # First install must not unexpectedly reconcile existing user resources.
        $ingresses = (Invoke-LbcNative 'kubectl' ($base + @('get', 'ingress', '-A', '-o', 'json'))) -join "`n" | ConvertFrom-Json
        $services = (Invoke-LbcNative 'kubectl' ($base + @('get', 'services', '-A', '-o', 'json'))) -join "`n" | ConvertFrom-Json
        if (@($ingresses.items).Count -gt 0 -or @($services.items | Where-Object { $_.spec.type -eq 'LoadBalancer' }).Count -gt 0) {
            throw 'Review existing Ingress/LoadBalancer resources before the first controller install.'
        }
    } elseif ($release[0].chart -ne 'aws-load-balancer-controller-3.6.0') {
        throw 'A different chart is already installed; review an upgrade separately.'
    }
    Write-LbcJson -Value (Get-LbcRuntimeValues $outputs) -Path $runtime
    Invoke-LbcNative $HelmCommand (@('upgrade', '--install', 'aws-load-balancer-controller', $chart, '-n', 'kube-system', '-f', (Join-Path $LbcStack 'helm-values.yaml'), '-f', $runtime, '--atomic', '--wait', '--timeout', '5m', '--history-max', '3') + $base)
} finally {
    Remove-Item -LiteralPath $runtime, $kubeconfig
}
