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

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket         = "oneaction-tfstate-123456789012"
    key            = "dev/network/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "oneaction-terraform-locks"
    encrypt        = true
  }
}

data "terraform_remote_state" "alb" {
  backend = "s3"
  config = {
    bucket         = "oneaction-tfstate-123456789012"
    key            = "dev/alb/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "oneaction-terraform-locks"
    encrypt        = true
  }
}

resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/oneaction/vpc-flow"
  retention_in_days = 7
  tags              = { Name = "oneaction-vpc-flow" }
}

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/oneaction/cluster"
  retention_in_days = 7
  tags              = { Name = "oneaction-eks-cluster" }
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "oneaction-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role.json
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow.arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "oneaction-vpc-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "rejects" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow.arn
  traffic_type    = "REJECT"
  vpc_id          = data.terraform_remote_state.network.outputs.vpc_id

  tags = { Name = "oneaction-vpc-rejects" }
}

resource "aws_sns_topic" "alerts" {
  name              = "oneaction-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = { Name = "oneaction-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "oneaction-alb-5xx"
  alarm_description   = "ALB generated 5XX responses exceeded the configured threshold."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.alb_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = { LoadBalancer = data.terraform_remote_state.alb.outputs.alb_arn_suffix }
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "oneaction-review-db-high-cpu"
  alarm_description   = "RDS CPU utilization is above 80 percent."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = { DBInstanceIdentifier = "oneaction-review-db" }
}

resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "oneaction-review-db-low-storage"
  alarm_description   = "RDS free storage is below the configured threshold."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = var.rds_free_storage_threshold_bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = { DBInstanceIdentifier = "oneaction-review-db" }
}

resource "aws_cloudwatch_metric_alarm" "nat_error_port_allocation" {
  alarm_name          = "oneaction-nat-error-port-allocation"
  alarm_description   = "NAT Gateway could not allocate a source port."
  namespace           = "AWS/NATGateway"
  metric_name         = "ErrorPortAllocation"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = { NatGatewayId = data.terraform_remote_state.network.outputs.nat_gateway_id }
}
