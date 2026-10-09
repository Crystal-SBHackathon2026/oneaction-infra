data "aws_iam_role" "admin" {
  for_each = var.admin_principal_arns
  name     = element(reverse(split("/", each.value)), 0)
}

resource "aws_eks_access_entry" "admin" {
  for_each      = var.admin_principal_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = data.aws_iam_role.admin[each.value].arn
  type          = "STANDARD"

  lifecycle {
    precondition {
      condition     = data.aws_iam_role.admin[each.value].arn == each.value
      error_message = "The supplied administrator ARN must match an existing IAM role, including its full path."
    }
  }
}

resource "aws_eks_access_policy_association" "admin" {
  for_each      = var.admin_principal_arns
  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.admin[each.value].principal_arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

# EKS creates the node-role access entry for a managed node group in API mode.
# Do not define a duplicate EC2_LINUX entry or manage aws-auth with Kubernetes.
