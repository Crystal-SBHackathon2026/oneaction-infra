# Install networking before compute; CoreDNS needs Ready nodes and comes later.
resource "aws_eks_addon" "networking" {
  for_each                    = toset(["vpc-cni", "kube-proxy"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = var.addon_versions[each.value]
  service_account_role_arn    = each.value == "vpc-cni" ? aws_iam_role.cni.arn : null
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_iam_role_policy_attachment.cni]
}

resource "aws_eks_addon" "runtime" {
  for_each                    = toset(["coredns", "eks-pod-identity-agent"])
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  addon_version               = var.addon_versions[each.value]
  resolve_conflicts_on_create = "NONE"
  resolve_conflicts_on_update = "PRESERVE"

  depends_on = [aws_eks_node_group.this]
}
