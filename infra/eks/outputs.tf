output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_arn" {
  value = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Set Argo CD destination.server to this endpoint after registering the cluster."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group_name" {
  value = aws_eks_node_group.this.node_group_name
}

output "node_role_arn" {
  value = aws_iam_role.node.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.cluster.arn
}

output "eks_log_group_name" {
  value = data.aws_cloudwatch_log_group.eks.name
}

output "addon_versions" {
  value = merge(
    { for name, addon in aws_eks_addon.networking : name => addon.addon_version },
    { for name, addon in aws_eks_addon.runtime : name => addon.addon_version },
  )
}
