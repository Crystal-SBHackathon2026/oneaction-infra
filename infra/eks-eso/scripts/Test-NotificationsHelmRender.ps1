[CmdletBinding()]
param(
    [string]$HelmCommand = 'helm',
    [string]$PythonCommand = 'python',
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [string]$Profile = 'sbhackathon2026-team',
    [switch]$CompareInstalled
)
. "$PSScriptRoot/Common.ps1"
$chart = Get-EsoChart -HelmCommand $HelmCommand -Directory $ArtifactDirectory
$values = Join-Path $EsoStack 'helm-values-argocd.yaml'
$renderPath = [IO.Path]::GetTempFileName()
$installedPath = [IO.Path]::GetTempFileName()
$kubeconfig = $null
try {
    Invoke-EsoNative $HelmCommand @('lint', $chart, '-f', $values, '--strict', '--kube-version', '1.36.4')
    # The platform release owns CRDs and webhook certificates. Its post-renderer
    # is intentionally not used for this controller-only release.
    $arguments = @('template', 'external-secrets-argocd', $chart, '-n', 'external-secrets', '-f', $values, '--kube-version', '1.36.4')
    if ($CompareInstalled) {
        $kubeconfig = New-EsoKubeconfig -Profile $Profile
        $arguments += @('--is-upgrade', '--dry-run=server', '--kubeconfig', $kubeconfig)
    }
    $render = (Invoke-EsoNative $HelmCommand $arguments) -join "`n"
    [IO.File]::WriteAllText($renderPath, $render, [Text.UTF8Encoding]::new($false))
    # Run the scope checks even when checking installed manifest parity.
    Invoke-EsoNative $PythonCommand @('-B', "$PSScriptRoot/check_notifications_render.py", $renderPath)
    if ($CompareInstalled) {
        $installed = (Invoke-EsoNative $HelmCommand @('get', 'manifest', 'external-secrets-argocd', '-n', 'external-secrets', '--kubeconfig', $kubeconfig)) -join "`n"
        [IO.File]::WriteAllText($installedPath, $installed, [Text.UTF8Encoding]::new($false))
        Invoke-EsoNative $PythonCommand @('-B', "$PSScriptRoot/check_notifications_render.py", $renderPath, $installedPath)
    }
} finally {
    foreach ($path in @($renderPath, $installedPath, $kubeconfig)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path }
    }
}
