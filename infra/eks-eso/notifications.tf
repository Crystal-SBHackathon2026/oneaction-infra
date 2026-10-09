# A separate identity for the argocd-only controller. The existing platform
# controller keeps its role, trust policy and read permissions unchanged.
locals {
  notifications_enabled            = var.review_service_secret_arn != null
  notifications_operator_namespace = "external-secrets"
  notifications_service_account    = "external-secrets-argocd"
  notifications_target_namespace   = "argocd"
}

data "aws_iam_policy_document" "notifications_trust" {
  count = local.notifications_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [local.cluster_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [local.notifications_operator_namespace]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [local.notifications_service_account]
    }
  }
}

resource "aws_iam_role" "notifications" {
  count              = local.notifications_enabled ? 1 : 0
  name               = "oneaction-external-secrets-argocd"
  assume_role_policy = data.aws_iam_policy_document.notifications_trust[0].json
  lifecycle {
    precondition {
      condition     = local.cluster_name == "oneaction" && local.cluster_arn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/oneaction"
      error_message = "Notifications Pod Identity must use the team oneaction cluster."
    }
    precondition {
      condition = (
        data.aws_secretsmanager_secret.review_service[0].arn == var.review_service_secret_arn &&
        var.review_service_secret_arn != local.secret_arn &&
        var.review_service_secret_arn != var.gitops_token_secret_arn
      )
      error_message = "Notifications must read the exact existing review-service Secret, separate from RDS and GitOps Secrets."
    }
    precondition {
      condition     = data.aws_secretsmanager_secret.review_service[0].kms_key_id == null || data.aws_secretsmanager_secret.review_service[0].kms_key_id == ""
      error_message = "An explicit review-service KMS key requires a separately reviewed scoped decryption policy."
    }
  }
}

resource "aws_iam_role_policy" "read_notifications" {
  count = local.notifications_enabled ? 1 : 0
  name  = "read-argocd-notifications-secret"
  role  = aws_iam_role.notifications[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = var.review_service_secret_arn
      Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
    }]
  })
}

resource "aws_eks_pod_identity_association" "notifications" {
  count           = local.notifications_enabled ? 1 : 0
  cluster_name    = local.cluster_name
  namespace       = local.notifications_operator_namespace
  service_account = local.notifications_service_account
  role_arn        = aws_iam_role.notifications[0].arn
  # Keep session tags enabled: they enforce the exact namespace and identity.
  depends_on = [aws_iam_role_policy.read_notifications]
}

output "notifications_role_arn" {
  value = local.notifications_enabled ? aws_iam_role.notifications[0].arn : null
}
output "notifications_association_id" {
  value = local.notifications_enabled ? aws_eks_pod_identity_association.notifications[0].association_id : null
}
output "notifications_operator_namespace" {
  value = local.notifications_operator_namespace
}
output "notifications_service_account" {
  value = local.notifications_service_account
}
output "notifications_target_namespace" {
  value = local.notifications_target_namespace
}
