[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$oneactionStack = Split-Path -Parent $PSScriptRoot
$oneactionTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('oneaction-input-test-' + [guid]::NewGuid().ToString() + '.json')
$oneactionCases = @(
    @{ Name = 'Multiple types with fixed launch-template type'; Values = @{ node_instance_types = @('t3.medium', 't3a.medium') }; Expected = 'Supply exactly one instance type' },
    @{ Name = 'World-open API'; Values = @{ public_access_cidrs = @('0.0.0.0/0') }; Expected = 'Supply at least one explicit IPv4 CIDR' },
    @{ Name = 'STS administrator'; Values = @{ admin_principal_arns = @('arn:aws:sts::123456789012:assumed-role/example/session') }; Expected = 'Supply existing IAM role ARNs' },
    @{ Name = 'Zero desired nodes'; Values = @{ node_scaling = @{ min = 2; desired = 0; max = 2 } }; Expected = 'Node counts must be integers' },
    @{ Name = 'ARM node with x86 AMI'; Values = @{ node_instance_types = @('t4g.medium') }; Expected = 'Use T3 or T3a x86_64' },
    @{ Name = 'Wrong workload region'; Values = @{ aws_region = 'us-east-1' }; Expected = 'The oneaction handoff requires the Seoul Region' },
    @{ Name = 'Incomplete add-on pins'; Values = @{ addon_versions = @{ coredns = 'v1.14.6-eksbuild.4' } }; Expected = 'Pin all four foundation add-ons' }
)

try {
    foreach ($test in $oneactionCases) {
        $test.Values | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $oneactionTemp -Encoding utf8
        $result = & terraform "-chdir=$oneactionStack" plan '-input=false' '-no-color' "-var-file=$oneactionTemp" 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 1 -or ($result -join "`n") -notmatch [regex]::Escape($test.Expected)) {
            throw "Input test failed to reject the intended condition: $($test.Name). Exit code: $exitCode."
        }
        Write-Output "PASS (Terraform rejected): $($test.Name)"
    }
} finally {
    if (Test-Path -LiteralPath $oneactionTemp) {
        Remove-Item -LiteralPath $oneactionTemp
    }
}
