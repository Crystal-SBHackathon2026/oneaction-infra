$ErrorActionPreference = 'Stop'
$LbcStack = Split-Path -Parent $PSScriptRoot

function Invoke-LbcNative {
    param([string]$Command, [string[]]$Arguments)
    $result = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
    return $result
}
function Get-LbcOutputs {
    $raw = (Invoke-LbcNative 'terraform' @("-chdir=$LbcStack", 'output', '-json')) -join "`n" | ConvertFrom-Json
    $values = @{}
    foreach ($property in $raw.PSObject.Properties) { $values[$property.Name] = $property.Value.value }
    if ($values.cluster_name -ne 'oneaction' -or $values.aws_region -ne 'ap-northeast-2' -or $values.role_arn -ne 'arn:aws:iam::123456789012:role/oneaction-aws-load-balancer-controller' -or $values.vpc_id -notmatch '^vpc-[a-f0-9]+$') {
        throw 'The applied IAM outputs do not match the oneaction deployment.'
    }
    return $values
}
function New-LbcKubeconfig {
    param([string]$Profile)
    $identity = (Invoke-LbcNative 'aws' @('sts', 'get-caller-identity', '--profile', $Profile, '--region', 'ap-northeast-2', '--output', 'json', '--no-cli-pager')) -join "`n" | ConvertFrom-Json
    if ($identity.Account -ne '123456789012') { throw 'Use the team account 123456789012.' }
    $path = [IO.Path]::GetTempFileName()
    try {
        Invoke-LbcNative 'aws' @('eks', 'update-kubeconfig', '--name', 'oneaction', '--region', 'ap-northeast-2', '--profile', $Profile, '--kubeconfig', $path) | Out-Null
        return $path
    } catch { Remove-Item -LiteralPath $path; throw }
}
function Write-LbcJson {
    param($Value, [string]$Path)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
}
function Get-LbcChart {
    param([string]$HelmCommand, [string]$Directory)
    $pins = Get-Content (Join-Path $LbcStack 'artifacts.json') -Raw | ConvertFrom-Json
    $path = Join-Path $Directory "aws-load-balancer-controller-$($pins.chartVersion).tgz"
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-LbcNative $HelmCommand @('pull', 'aws-load-balancer-controller', '--repo', 'https://aws.github.io/eks-charts', '--version', $pins.chartVersion, '--destination', $Directory) | Out-Null
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pins.chartSha256) { throw 'Chart checksum mismatch.' }
    if ((Get-FileHash -LiteralPath (Join-Path $LbcStack 'iam-policy-v3.6.0.json') -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pins.policySha256) { throw 'Upstream IAM policy checksum mismatch.' }
    return $path
}
function Get-LbcRuntimeValues {
    param($Outputs)
    return @{
        clusterName = $Outputs.cluster_name; region = $Outputs.aws_region; vpcId = $Outputs.vpc_id
        serviceAccount = @{ annotations = @{
            'eks.amazonaws.com/role-arn' = $Outputs.role_arn
            'eks.amazonaws.com/sts-regional-endpoints' = 'true'
        } }
    }
}
