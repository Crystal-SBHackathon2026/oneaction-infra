resource "aws_eks_cluster" "this" {
  name                          = local.cluster_name
  role_arn                      = aws_iam_role.cluster.arn
  version                       = var.cluster_version
  bootstrap_self_managed_addons = false
  enabled_cluster_log_types     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = false
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids              = data.terraform_remote_state.network.outputs.private_eks_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = sort(tolist(var.public_access_cidrs))
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = (
        length(data.aws_subnet.eks) == 2 &&
        length(toset([for subnet in data.aws_subnet.eks : subnet.availability_zone])) == 2 &&
        alltrue([for subnet in data.aws_subnet.eks :
          subnet.vpc_id == data.terraform_remote_state.network.outputs.vpc_id &&
          !subnet.map_public_ip_on_launch &&
          lookup(subnet.tags, "kubernetes.io/role/internal-elb", "") == "1" &&
          lookup(subnet.tags, "kubernetes.io/cluster/${local.cluster_name}", "") == "shared"
        ]) &&
        data.aws_security_group.node_extra.vpc_id == data.terraform_remote_state.network.outputs.vpc_id
      )
      error_message = "The handoff requires two tagged private EKS subnets in different AZs and the extra SG in the existing VPC."
    }

    precondition {
      condition = (
        data.aws_cloudwatch_log_group.eks.name == "/aws/eks/${local.cluster_name}/cluster" &&
        data.aws_cloudwatch_log_group.eks.retention_in_days == 7
      )
      error_message = "The observability-owned EKS log group must already exist with seven-day retention."
    }
  }

  tags = { Name = local.cluster_name }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}
