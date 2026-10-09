[CmdletBinding()]
param(
    [string]$HelmCommand = 'helm', [string]$PythonCommand = 'python',
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [string]$PlanPath,
    [string]$Profile = 'sbhackathon2026-team',
    [switch]$CompareInstalled
)
. "$PSScriptRoot/Common.ps1"
$chart = Get-LbcChart -HelmCommand $HelmCommand -Directory $ArtifactDirectory
$runtime = [IO.Path]::GetTempFileName()
$renderPath = [IO.Path]::GetTempFileName()
$installedPath = [IO.Path]::GetTempFileName()
$kubeconfig = $null
try {
    if ($CompareInstalled) {
        $outputs = Get-LbcOutputs
        $kubeconfig = New-LbcKubeconfig -Profile $Profile
    } else {
        if (-not $PlanPath) { throw 'Supply the checked real Terraform plan JSON.' }
        $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
        $outputs = @{
            cluster_name = $plan.planned_values.outputs.cluster_name.value
            aws_region = $plan.planned_values.outputs.aws_region.value
            vpc_id = $plan.planned_values.outputs.vpc_id.value
            role_arn = 'arn:aws:iam::123456789012:role/oneaction-aws-load-balancer-controller'
        }
    }
    Write-LbcJson (Get-LbcRuntimeValues $outputs) $runtime
    $args = @('template', 'aws-load-balancer-controller', $chart, '-n', 'kube-system', '-f', (Join-Path $LbcStack 'helm-values.yaml'), '-f', $runtime, '--kube-version', '1.36.4')
    if ($CompareInstalled) {
        $args += @('--is-upgrade', '--dry-run=server', '--kubeconfig', $kubeconfig)
    } else {
        Invoke-LbcNative $HelmCommand @('lint', $chart, '-f', (Join-Path $LbcStack 'helm-values.yaml'), '-f', $runtime, '--strict', '--kube-version', '1.36.4')
        $args += '--include-crds'
    }
    $render = (Invoke-LbcNative $HelmCommand $args) -join "`n"
    [IO.File]::WriteAllText($renderPath, $render, [Text.UTF8Encoding]::new($false))
    if ($CompareInstalled) {
        $installed = (Invoke-LbcNative $HelmCommand @('get','manifest','aws-load-balancer-controller','-n','kube-system','--kubeconfig',$kubeconfig)) -join "`n"
        [IO.File]::WriteAllText($installedPath, $installed, [Text.UTF8Encoding]::new($false))
        Invoke-LbcNative $PythonCommand @("$PSScriptRoot/check_render.py", $renderPath, $installedPath)
    } else {
        Invoke-LbcNative $PythonCommand @("$PSScriptRoot/check_render.py", $renderPath)
    }
} finally {
    foreach ($path in @($runtime, $renderPath, $installedPath, $kubeconfig)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path }
    }
}
