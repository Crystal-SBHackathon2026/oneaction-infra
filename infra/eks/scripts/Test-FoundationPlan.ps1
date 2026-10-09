[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
$oneactionPlan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$oneactionChecks = 0

function Assert-PlanCondition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "Plan safety check failed: $Message" }
    $script:oneactionChecks++
}

function Get-PlannedResource {
    param([string]$Address)
    $resource = @($oneactionPlan.resource_changes | Where-Object address -EQ $Address)
    Assert-PlanCondition ($resource.Count -eq 1) "Expected exactly one $Address."
    return $resource[0].change.after
}

function Get-ConfiguredResource {
    param([string]$Address)
    $resource = @($oneactionPlan.configuration.root_module.resources | Where-Object address -EQ $Address)
    Assert-PlanCondition ($resource.Count -eq 1) "Missing configuration for $Address."
    return $resource[0]
}

$oneactionAllowedAddresses = @(
    'aws_eks_cluster.this',
    'aws_eks_node_group.this',
    'aws_launch_template.node',
    'aws_iam_openid_connect_provider.cluster',
    'aws_iam_role.cluster', 'aws_iam_role.node', 'aws_iam_role.cni',
    'aws_iam_role_policy_attachment.cluster', 'aws_iam_role_policy_attachment.node', 'aws_iam_role_policy_attachment.cni',
    'aws_eks_access_entry.admin', 'aws_eks_access_policy_association.admin',
    'aws_eks_addon.networking', 'aws_eks_addon.runtime'
)

Assert-PlanCondition ($oneactionPlan.terraform_version -eq '1.5.7') 'Validate the team-pinned Terraform 1.5.7 plan.'
Assert-PlanCondition ((@($oneactionPlan.configuration.provider_config.aws.expressions.allowed_account_ids.constant_value) -join ',') -eq '123456789012') 'Provider writes must be restricted to the team account.'
Assert-PlanCondition ($oneactionPlan.variables.aws_region.value -eq 'ap-northeast-2') 'Use the Seoul workload Region.'
Assert-PlanCondition ($null -eq $oneactionPlan.configuration.root_module.module_calls) 'Unexpected child module must be reviewed.'
foreach ($resource in $oneactionPlan.resource_changes) {
    if ($resource.mode -ne 'managed') { continue }
    $baseAddress = ($resource.address -split '\[')[0]
    Assert-PlanCondition ($oneactionAllowedAddresses -contains $baseAddress) "Unexpected write outside EKS foundation: $($resource.address)."
    $actions = @($resource.change.actions)
    Assert-PlanCondition ($actions.Count -eq 1 -and $actions[0] -in @('create', 'no-op')) "Update/delete/replacement requires review: $($resource.address)."
    if ($null -ne $resource.change.after.tags_all) {
        Assert-PlanCondition ($resource.change.after.tags_all.Project -eq 'oneaction' -and $resource.change.after.tags_all.Env -eq 'dev' -and -not [string]::IsNullOrWhiteSpace($resource.change.after.tags_all.Owner)) "Missing common tags: $($resource.address)."
    }
}

foreach ($stackName in @('network', 'observability')) {
    $state = @($oneactionPlan.prior_state.values.root_module.resources | Where-Object address -EQ "data.terraform_remote_state.$stackName")
    Assert-PlanCondition ($state.Count -eq 1) "Missing refreshed $stackName state."
    Assert-PlanCondition ($state[0].values.config.key -eq "dev/$stackName/terraform.tfstate" -and $state[0].values.config.bucket -eq 'oneaction-tfstate-123456789012' -and $state[0].values.config.region -eq 'ap-northeast-2') "Wrong remote state configuration for $stackName."
}

$cluster = Get-PlannedResource 'aws_eks_cluster.this'
$node = Get-PlannedResource 'aws_eks_node_group.this'
$launch = Get-PlannedResource 'aws_launch_template.node'
# Terraform 1.5 stores data read successfully during planning in prior_state.
$network = @($oneactionPlan.prior_state.values.root_module.resources | Where-Object address -EQ 'data.terraform_remote_state.network')[0].values.outputs
Assert-PlanCondition (@($network.private_eks_subnet_ids).Count -eq 2) 'The plan must include refreshed network state with two private EKS subnets.'

Assert-PlanCondition ($cluster.name -eq 'oneaction') 'Cluster name must match existing tags and log group.'
Assert-PlanCondition ($cluster.access_config[0].authentication_mode -eq 'API' -and -not $cluster.access_config[0].bootstrap_cluster_creator_admin_permissions) 'Administration must use explicit access entries.'
Assert-PlanCondition ($cluster.upgrade_policy[0].support_type -eq 'STANDARD') 'Extended support changes the cost model.'
Assert-PlanCondition (-not $cluster.bootstrap_self_managed_addons) 'Avoid ownership conflicts with managed add-ons.'
Assert-PlanCondition ($cluster.vpc_config[0].endpoint_private_access -and $cluster.vpc_config[0].endpoint_public_access) 'Keep private node access and restricted operator access enabled.'
$cidrs = @($cluster.vpc_config[0].public_access_cidrs)
Assert-PlanCondition ($cidrs.Count -gt 0) 'The public API allowlist cannot be empty.'
foreach ($cidr in $cidrs) {
    Assert-PlanCondition ($cidr -match '^\d+\.\d+\.\d+\.\d+/(2[4-9]|3[0-2])$') 'Public API access must be /24 or narrower.'
}
Assert-PlanCondition (@($cluster.enabled_cluster_log_types).Count -eq 5) 'Enable all five control-plane logs.'
Assert-PlanCondition (@(Compare-Object @($cluster.vpc_config[0].subnet_ids) @($network.private_eks_subnet_ids)).Count -eq 0) 'Control plane must use the existing private EKS subnets.'
Assert-PlanCondition (@(Compare-Object @($node.subnet_ids) @($network.private_eks_subnet_ids)).Count -eq 0) 'Nodes must use the existing private EKS subnets.'
Assert-PlanCondition ($node.capacity_type -eq 'ON_DEMAND' -and $node.ami_type -eq 'AL2023_x86_64_STANDARD') 'Node capacity and AMI must match the reviewed design.'
Assert-PlanCondition ($node.scaling_config[0].min_size -ge 1 -and $node.scaling_config[0].min_size -le $node.scaling_config[0].desired_size -and $node.scaling_config[0].desired_size -le $node.scaling_config[0].max_size) 'Node scaling bounds are invalid.'

$launchConfig = Get-ConfiguredResource 'aws_launch_template.node'
$sgReferences = @($launchConfig.expressions.vpc_security_group_ids.references)
Assert-PlanCondition (($sgReferences -join ' ') -match 'aws_eks_cluster\.this\.vpc_config' -and $sgReferences -contains 'data.terraform_remote_state.network.outputs.eks_node_extra_security_group_id') 'Custom node SGs must include both the cluster SG and existing extra SG.'
Assert-PlanCondition ($launch.metadata_options[0].http_tokens -eq 'required' -and $launch.metadata_options[0].http_put_response_hop_limit -eq 1) 'Require IMDSv2 and block ordinary Pods from node-role credentials.'
Assert-PlanCondition ($launch.block_device_mappings[0].ebs[0].encrypted -eq 'true') 'Node root volumes must be encrypted.'
Assert-PlanCondition ($launch.credit_specification[0].cpu_credits -eq 'standard') 'Avoid unlimited CPU-credit charges.'
Assert-PlanCondition ($launch.instance_type -eq $oneactionPlan.variables.node_instance_types.value[0]) 'Provider 5.100 requires the burstable instance type in the launch template to send CPU credits.'

$nodeConfig = Get-ConfiguredResource 'aws_eks_node_group.this'
Assert-PlanCondition (@($nodeConfig.expressions.instance_types.constant_value).Count -eq 0) 'Do not specify the instance type in both the node group and launch template.'
Assert-PlanCondition (@($nodeConfig.depends_on) -contains 'aws_eks_addon.networking') 'Install networking before nodes.'
$runtimeConfig = Get-ConfiguredResource 'aws_eks_addon.runtime'
Assert-PlanCondition (@($runtimeConfig.depends_on) -contains 'aws_eks_node_group.this') 'CoreDNS must wait for compute to avoid a creation deadlock.'
$addons = @($oneactionPlan.resource_changes | Where-Object { $_.mode -eq 'managed' -and $_.type -eq 'aws_eks_addon' })
Assert-PlanCondition (@(Compare-Object @($addons.change.after.addon_name) @('vpc-cni', 'kube-proxy', 'coredns', 'eks-pod-identity-agent')).Count -eq 0) 'All four foundation add-ons are required.'
foreach ($addon in $addons) {
    Assert-PlanCondition (-not [string]::IsNullOrWhiteSpace($addon.change.after.addon_version)) "Pin a resolved version for $($addon.address)."
    Assert-PlanCondition ($addon.change.after.resolve_conflicts_on_create -eq 'NONE') 'Do not overwrite unmanaged add-ons on create.'
}
$cniConfig = Get-ConfiguredResource 'aws_eks_addon.networking'
Assert-PlanCondition (@($cniConfig.expressions.service_account_role_arn.references) -contains 'aws_iam_role.cni.arn') 'CNI must use its separate IAM role.'
$nodePolicies = @($oneactionPlan.resource_changes | Where-Object { $_.address -match '^aws_iam_role_policy_attachment\.node\[' })
Assert-PlanCondition (@($nodePolicies.change.after.policy_arn | Where-Object { $_ -match 'AmazonEKS_CNI_Policy|AdministratorAccess' }).Count -eq 0) 'Node role must not receive CNI or administrator policy.'
Assert-PlanCondition (@(Compare-Object @($nodePolicies.change.after.policy_arn) @('arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy', 'arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly')).Count -eq 0) 'Node role requires exactly the reviewed worker and image-pull policies.'

$admins = @($oneactionPlan.resource_changes | Where-Object { $_.type -eq 'aws_eks_access_entry' -and $_.mode -eq 'managed' })
Assert-PlanCondition ($admins.Count -gt 0) 'At least one explicit administrator entry is required.'
foreach ($admin in $admins) {
    Assert-PlanCondition ($admin.change.after.principal_arn -match '^arn:aws:iam::123456789012:role/') 'Use stable team IAM role ARNs, not STS sessions.'
}
Assert-PlanCondition ($oneactionPlan.planned_values.outputs.eks_log_group_name.value -eq '/aws/eks/oneaction/cluster') 'Reuse the observability-owned log group.'

Write-Output "PASS: $oneactionChecks foundation plan safety checks."
