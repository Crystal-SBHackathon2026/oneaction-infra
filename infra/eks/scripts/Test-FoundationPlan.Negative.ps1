[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
$oneactionOriginal = Get-Content -LiteralPath $PlanPath -Raw
$oneactionChecker = Join-Path $PSScriptRoot 'Test-FoundationPlan.ps1'
$oneactionTemporary = Join-Path ([System.IO.Path]::GetTempPath()) ("oneaction-plan-test-" + [guid]::NewGuid().ToString() + '.json')
$oneactionTests = [ordered]@{
    'Omit the launch-template instance type required for CPU credits' = {
        param($plan)
        ($plan.resource_changes | Where-Object address -EQ 'aws_launch_template.node').change.after.instance_type = ''
    }
    'Permit another AWS account' = {
        param($plan)
        $plan.configuration.provider_config.aws.expressions.allowed_account_ids.constant_value = @('111122223333')
    }
    'Delete an existing cluster' = {
        param($plan)
        ($plan.resource_changes | Where-Object address -EQ 'aws_eks_cluster.this').change.actions = @('delete')
    }
    'Create a duplicate log group' = {
        param($plan)
        $plan.resource_changes += [pscustomobject]@{ address = 'aws_cloudwatch_log_group.duplicate'; mode = 'managed'; type = 'aws_cloudwatch_log_group'; change = @{ actions = @('create'); after = @{} } }
    }
    'Open API access to the internet' = {
        param($plan)
        ($plan.resource_changes | Where-Object address -EQ 'aws_eks_cluster.this').change.after.vpc_config[0].public_access_cidrs = @('0.0.0.0/0')
    }
    'Omit the cluster SG from custom nodes' = {
        param($plan)
        ($plan.configuration.root_module.resources | Where-Object address -EQ 'aws_launch_template.node').expressions.vpc_security_group_ids.references = @('data.terraform_remote_state.network.outputs.eks_node_extra_security_group_id')
    }
    'Use an STS session as the administrator' = {
        param($plan)
        ($plan.resource_changes | Where-Object type -EQ 'aws_eks_access_entry').change.after.principal_arn = 'arn:aws:sts::123456789012:assumed-role/example/session'
    }
    'Wait for CoreDNS before creating nodes' = {
        param($plan)
        ($plan.configuration.root_module.resources | Where-Object address -EQ 'aws_eks_addon.runtime').depends_on = @('aws_eks_cluster.this')
    }
    'Grant CNI permissions to the node role' = {
        param($plan)
        ($plan.resource_changes | Where-Object { $_.address -match '^aws_iam_role_policy_attachment\.node\[' } | Select-Object -First 1).change.after.policy_arn = 'arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy'
    }
}

try {
    foreach ($test in $oneactionTests.GetEnumerator()) {
        $plan = $oneactionOriginal | ConvertFrom-Json
        & $test.Value $plan
        $plan | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $oneactionTemporary -Encoding utf8
        $rejected = $false
        try { & $oneactionChecker -PlanPath $oneactionTemporary | Out-Null }
        catch {
            if ($_.Exception.Message -notlike 'Plan safety check failed:*') { throw }
            $rejected = $true
        }
        if (-not $rejected) { throw "Unsafe test plan was accepted: $($test.Key)" }
        Write-Output "PASS (rejected): $($test.Key)"
    }
} finally {
    if (Test-Path -LiteralPath $oneactionTemporary) {
        Remove-Item -LiteralPath $oneactionTemporary
    }
}
