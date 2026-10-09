variable "aws_profile" {
  type    = string
  default = ""
}
variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "Use the Seoul workload region ap-northeast-2."
  }
}
provider "aws" {
  profile             = var.aws_profile == "" ? null : var.aws_profile
  region              = var.aws_region
  allowed_account_ids = ["123456789012"]
  default_tags {
    tags = { Project = "oneaction", Owner = "hyeyeon.kim", Env = "dev" }
  }
}
locals {
  state_config = {
    bucket         = "oneaction-tfstate-123456789012"
    region         = var.aws_region
    dynamodb_table = "oneaction-terraform-locks"
    encrypt        = true
  }
  cluster_name = data.terraform_remote_state.eks.outputs.cluster_name
  cluster_arn  = data.terraform_remote_state.eks.outputs.cluster_arn
  secret_arn   = data.terraform_remote_state.database.outputs.db_master_user_secret_arn
}
data "terraform_remote_state" "eks" {
  backend = "s3"
  config  = merge(local.state_config, { key = "dev/eks/terraform.tfstate" })
}
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = merge(local.state_config, { key = "dev/database/terraform.tfstate" })
}
# Metadata only. Never use aws_secretsmanager_secret_version in Terraform.
data "aws_secretsmanager_secret" "rds" {
  arn = local.secret_arn
}
data "aws_iam_policy_document" "trust" {
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
      values   = ["external-secrets"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = ["external-secrets"]
    }
  }
}
resource "aws_iam_role" "eso" {
  name               = "oneaction-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  lifecycle {
    precondition {
      condition     = local.cluster_name == "oneaction" && local.cluster_arn == "arn:aws:eks:ap-northeast-2:123456789012:cluster/oneaction"
      error_message = "The EKS state must reference the team oneaction cluster."
    }
    precondition {
      condition     = can(regex("^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:rds!db-", local.secret_arn))
      error_message = "Use the existing RDS-managed Secret in the team account and region."
    }
    precondition {
      condition     = data.aws_secretsmanager_secret.rds.kms_key_id == null || data.aws_secretsmanager_secret.rds.kms_key_id == ""
      error_message = "A customer-managed KMS key needs a separately reviewed scoped decryption policy."
    }
  }
}
resource "aws_iam_role_policy" "read_rds" {
  name = "read-review-db-secret"
  role = aws_iam_role.eso.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = local.secret_arn
      Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
    }]
  })
}
resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = local.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
  # Session tags are enabled by default; the role trust requires them.
  depends_on = [aws_iam_role_policy.read_rds]
}
output "cluster_name" { value = local.cluster_name }
output "aws_region" { value = var.aws_region }
output "role_arn" { value = aws_iam_role.eso.arn }
output "secret_arn" { value = local.secret_arn }
output "association_id" { value = aws_eks_pod_identity_association.eso.association_id }
output "db_endpoint" { value = data.terraform_remote_state.database.outputs.db_endpoint }
output "operator_namespace" { value = "external-secrets" }
output "target_namespace" { value = "platform" }
