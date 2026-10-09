$ErrorActionPreference = 'Stop'
$EsoStack = Split-Path -Parent $PSScriptRoot

function Invoke-EsoNative {
    param([string]$Command, [string[]]$Arguments)
    $result = & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE)." }
    return $result
}
function Get-EsoOutputs {
    $raw = (Invoke-EsoNative 'terraform' @("-chdir=$EsoStack", 'output', '-json')) -join "`n" | ConvertFrom-Json
    $values = @{}
    foreach ($property in $raw.PSObject.Properties) { $values[$property.Name] = $property.Value.value }
    if ($values.cluster_name -ne 'oneaction' -or $values.aws_region -ne 'ap-northeast-2' -or $values.role_arn -ne 'arn:aws:iam::123456789012:role/oneaction-external-secrets' -or $values.secret_arn -notmatch '^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-' -or $values.target_namespace -ne 'platform' -or $values.operator_namespace -ne 'external-secrets') {
        throw 'The IAM outputs do not match the reviewed oneaction ESO deployment.'
    }
    return $values
}
function New-EsoKubeconfig {
    param([string]$Profile)
    $identity = (Invoke-EsoNative 'aws' @('sts','get-caller-identity','--profile',$Profile,'--region','ap-northeast-2','--output','json','--no-cli-pager')) -join "`n" | ConvertFrom-Json
    if ($identity.Account -ne '123456789012') { throw 'Use team account 123456789012.' }
    $path = [IO.Path]::GetTempFileName()
    try {
        Invoke-EsoNative 'aws' @('eks','update-kubeconfig','--name','oneaction','--region','ap-northeast-2','--profile',$Profile,'--kubeconfig',$path) | Out-Null
        return $path
    } catch { Remove-Item -LiteralPath $path; throw }
}
function Write-EsoJson {
    param($Value, [string]$Path)
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 30), [Text.UTF8Encoding]::new($false))
}
function Get-EsoChart {
    param([string]$HelmCommand, [string]$Directory)
    $pins = Get-Content (Join-Path $EsoStack 'artifacts.json') -Raw | ConvertFrom-Json
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $path = Join-Path $Directory "external-secrets-$($pins.chartVersion).tgz"
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-EsoNative $HelmCommand @('pull','external-secrets','--repo','https://charts.external-secrets.io','--version',$pins.chartVersion,'--destination',$Directory) | Out-Null
    }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $pins.chartSha256) { throw 'ESO chart checksum mismatch.' }
    return $path
}
function Write-EsoSyncManifest {
    param([string]$SecretArn, [string]$Path)
    if ($SecretArn -notmatch '^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-[a-zA-Z0-9-]+$') { throw 'Unexpected RDS Secret ARN.' }
    $template = Get-Content (Join-Path $EsoStack 'manifests/secret-sync.yaml') -Raw
    [IO.File]::WriteAllText($Path, $template.Replace('__RDS_SECRET_ARN__', $SecretArn), [Text.UTF8Encoding]::new($false))
}
