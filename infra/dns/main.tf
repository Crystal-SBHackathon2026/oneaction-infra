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

provider "aws" {
  alias   = "us_east_1"
  profile = var.aws_profile == "" ? null : var.aws_profile
  region  = "us-east-1"

  default_tags {
    tags = {
      Project = "oneaction"
      Owner   = var.owner
      Env     = "dev"
    }
  }
}

resource "aws_route53_zone" "this" {
  name = var.domain_name
  tags = { Name = var.domain_name }
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle { create_before_destroy = true }
  tags = { Name = "oneaction-wildcard-certificate" }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = {
    for option in aws_acm_certificate.this.domain_validation_options : option.domain_name => {
      name   = option.resource_record_name
      record = option.resource_record_value
      type   = option.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for record in aws_route53_record.certificate_validation : record.fqdn]
}

resource "aws_route53_record" "caa" {
  zone_id = aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "CAA"
  ttl     = 300
  records = ["0 issue \"amazon.com\""]
}

resource "aws_cloudwatch_log_group" "route53_queries" {
  provider          = aws.us_east_1
  name              = "/aws/route53/${var.domain_name}"
  retention_in_days = 7
  tags              = { Name = "oneaction-route53-query-logs" }
}

data "aws_iam_policy_document" "route53_query_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.route53_queries.arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["route53.amazonaws.com"]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "route53_query_logs" {
  provider        = aws.us_east_1
  policy_name     = "oneaction-route53-query-logs"
  policy_document = data.aws_iam_policy_document.route53_query_logs.json
}

resource "aws_route53_query_log" "this" {
  cloudwatch_log_group_arn = aws_cloudwatch_log_group.route53_queries.arn
  zone_id                  = aws_route53_zone.this.zone_id

  depends_on = [aws_cloudwatch_log_resource_policy.route53_query_logs]
}
