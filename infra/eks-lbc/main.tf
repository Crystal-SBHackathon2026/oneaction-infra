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
variable "owner" {
  type    = string
  default = "hyeyeon.kim"
}
provider "aws" {
  profile             = var.aws_profile == "" ? null : var.aws_profile
  region              = var.aws_region
  allowed_account_ids = ["123456789012"]
  default_tags {
    tags = { Project = "oneaction", Owner = var.owner, Env = "dev" }
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
  vpc_id       = data.terraform_remote_state.network.outputs.vpc_id
}
data "terraform_remote_state" "eks" {
  backend = "s3"
  config  = merge(local.state_config, { key = "dev/eks/terraform.tfstate" })
}
data "terraform_remote_state" "network" {
  backend = "s3"
  config  = merge(local.state_config, { key = "dev/network/terraform.tfstate" })
}
data "aws_iam_openid_connect_provider" "eks" {
  arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
}
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${trimprefix(data.aws_iam_openid_connect_provider.eks.url, "https://")}:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "${trimprefix(data.aws_iam_openid_connect_provider.eks.url, "https://")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}
locals {
  upstream_policy = jsondecode(file("${path.module}/iam-policy-v3.6.0.json"))
  # WAF/Shield are disabled in Helm. Preserve the matching release's other actions.
  statements = [for statement in local.upstream_policy.Statement : merge(statement, {
    Action = [for action in statement.Action : action if !can(regex("^(waf-regional|wafv2|shield):", action)) && action != "elasticloadbalancing:SetWebAcl"]
    # CreateSecurityGroup authorizes both the destination VPC and the new SG.
    # ec2:Vpc is not a supported condition key for this creation action.
    Resource = contains(statement.Action, "ec2:CreateSecurityGroup") ? [
      "arn:aws:ec2:${var.aws_region}:123456789012:vpc/${local.vpc_id}",
      "arn:aws:ec2:${var.aws_region}:123456789012:security-group/*"
      ] : [for resource in flatten([statement.Resource]) :
      replace(replace(resource, "arn:aws:ec2:*:*:", "arn:aws:ec2:${var.aws_region}:123456789012:"), "arn:aws:elasticloadbalancing:*:*:", "arn:aws:elasticloadbalancing:${var.aws_region}:123456789012:")
    ]
    Condition = merge(try(statement.Condition, {}), {
      StringEquals = merge(try(statement.Condition.StringEquals, {}),
        try(statement.Condition.Null["aws:ResourceTag/elbv2.k8s.aws/cluster"], "") == "false" ? { "aws:ResourceTag/elbv2.k8s.aws/cluster" = local.cluster_name } : {},
        try(statement.Condition.Null["aws:RequestTag/elbv2.k8s.aws/cluster"], "") == "false" ? { "aws:RequestTag/elbv2.k8s.aws/cluster" = local.cluster_name } : {},
        alltrue([for action in statement.Action : can(regex("^(ec2|elasticloadbalancing):", action))]) ? { "aws:RequestedRegion" = var.aws_region } : {}
      )
      }, length([for action in statement.Action : action if contains(["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress", "ec2:DeleteSecurityGroup"], action)]) > 0 ? {
      ArnEquals = { "ec2:Vpc" = "arn:aws:ec2:${var.aws_region}:123456789012:vpc/${local.vpc_id}" }
    } : {})
  })]
}
resource "aws_iam_role" "controller" {
  name               = "${local.cluster_name}-aws-load-balancer-controller"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  lifecycle {
    precondition {
      condition     = local.cluster_name == "oneaction"
      error_message = "The EKS state must reference oneaction."
    }
  }
}
# Scoped release policy exceeds 6 KiB: use the dedicated role's 10 KiB
# inline quota rather than widening permissions to fit the 6 KiB managed quota.
resource "aws_iam_role_policy" "controller" {
  name = "${local.cluster_name}-aws-load-balancer-controller"
  role = aws_iam_role.controller.name
  policy = jsonencode({ Version = "2012-10-17", Statement = [for statement in local.statements : merge(
    { for key, value in statement : key => value if key != "Condition" },
    length([for operator, conditions in statement.Condition : operator if length(conditions) > 0]) > 0 ? {
      Condition = { for operator, conditions in statement.Condition : operator => conditions if length(conditions) > 0 }
    } : {}
  )] })
}
output "cluster_name" { value = local.cluster_name }
output "aws_region" { value = var.aws_region }
output "vpc_id" { value = local.vpc_id }
output "role_arn" { value = aws_iam_role.controller.arn }
