variable "review_service_secret_arn" {
  description = "Full ARN of the existing review-service Claude Secret. Null disables its read policy."
  type        = string
  default     = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-GhIjKl"
  validation {
    condition = var.review_service_secret_arn == null ? true : can(regex(
      "^arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:oneaction/review-service-[A-Za-z0-9]{6}$",
      var.review_service_secret_arn
    ))
    error_message = "Use the full oneaction/review-service ARN in team account 123456789012 and Seoul, without wildcards."
  }
}

# Metadata only. Its owner stores the API key outside Terraform.
data "aws_secretsmanager_secret" "review_service" {
  count = var.review_service_secret_arn == null ? 0 : 1
  arn   = var.review_service_secret_arn
}

resource "aws_iam_role_policy" "read_review_service" {
  count = var.review_service_secret_arn == null ? 0 : 1
  name  = "read-review-service-secret"
  role  = aws_iam_role.eso.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = var.review_service_secret_arn
      Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
    }]
  })
  lifecycle {
    precondition {
      condition = (
        data.aws_secretsmanager_secret.review_service[0].arn == var.review_service_secret_arn &&
        var.review_service_secret_arn != local.secret_arn &&
        var.review_service_secret_arn != var.gitops_token_secret_arn
      )
      error_message = "Use the exact existing review-service Secret, separate from the RDS and GitOps Secrets."
    }
    precondition {
      condition     = data.aws_secretsmanager_secret.review_service[0].kms_key_id == null || data.aws_secretsmanager_secret.review_service[0].kms_key_id == ""
      error_message = "An explicit KMS key needs its key type and scoped decryption permission checked before granting access."
    }
  }
}

output "review_service_secret_arn" {
  value = var.review_service_secret_arn
}
