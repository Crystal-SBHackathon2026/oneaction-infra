provider "aws" {
  profile = var.aws_profile == "" ? null : var.aws_profile
  region  = var.aws_region

  default_tags {
    tags = {
      Project = "oneaction"
      Owner   = var.owner
      Env     = "dev"
    }
  }
}

locals {
  review_bucket = "oneaction-review-docs-${var.account_id}"
  logs_bucket   = "oneaction-logs-${var.account_id}"
  review_prefixes = toset([
    "rules/aws/",
    "rules/gcp/",
    "rules/local/",
    "rules/any/",
    "incidents/",
    "guides/",
  ])
}

resource "aws_s3_bucket" "review_docs" {
  bucket = local.review_bucket
  tags   = { Name = local.review_bucket }
}

resource "aws_s3_bucket_ownership_controls" "review_docs" {
  bucket = aws_s3_bucket.review_docs.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "review_docs" {
  bucket                  = aws_s3_bucket.review_docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "review_docs" {
  bucket = aws_s3_bucket.review_docs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "review_docs" {
  bucket = aws_s3_bucket.review_docs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_object" "review_prefixes" {
  for_each = local.review_prefixes
  bucket   = aws_s3_bucket.review_docs.id
  key      = each.value
  content  = ""
}

resource "aws_s3_bucket" "logs" {
  bucket = local.logs_bucket
  tags   = { Name = local.logs_bucket }
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "delete-alb-access-logs-after-30-days"
    status = "Enabled"

    filter { prefix = "alb/" }

    expiration { days = 30 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid = "AllowALBLogDelivery"
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/AWSLogs/${var.account_id}/*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }

  statement {
    sid = "AllowALBLogDeliveryAclCheck"
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]
  }

  statement {
    sid = "DenyInsecureTransport"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}
