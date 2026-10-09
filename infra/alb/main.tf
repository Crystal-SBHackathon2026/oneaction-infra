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
  state_config = {
    bucket         = "oneaction-tfstate-123456789012"
    region         = var.aws_region
    dynamodb_table = "oneaction-terraform-locks"
    encrypt        = true
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config  = merge(local.state_config, { key = "dev/network/terraform.tfstate" })
}

data "terraform_remote_state" "storage" {
  backend = "s3"
  config  = merge(local.state_config, { key = "dev/storage/terraform.tfstate" })
}

resource "aws_lb" "platform" {
  name               = "oneaction-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [data.terraform_remote_state.network.outputs.alb_security_group_id]
  subnets            = data.terraform_remote_state.network.outputs.public_subnet_ids

  enable_deletion_protection = false

  access_logs {
    bucket  = data.terraform_remote_state.storage.outputs.logs_bucket_name
    prefix  = "alb"
    enabled = true
  }

  tags = { Name = "oneaction-alb" }
}

resource "aws_lb_target_group" "platform" {
  name        = "platform-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  health_check {
    enabled             = true
    path                = "/healthz"
    protocol            = "HTTP"
    port                = "traffic-port"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "platform-tg" }
}

resource "aws_lb_listener" "https" {
  count = var.certificate_arn == "" ? 0 : 1

  load_balancer_arn = aws_lb.platform.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.platform.arn
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.platform.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = var.certificate_arn == "" ? "forward" : "redirect"
    target_group_arn = var.certificate_arn == "" ? aws_lb_target_group.platform.arn : null

    dynamic "redirect" {
      for_each = var.certificate_arn == "" ? [] : [1]
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }
}

resource "aws_route53_record" "app" {
  count = var.hosted_zone_id != "" && var.domain_name != "" ? 1 : 0

  zone_id = var.hosted_zone_id
  name    = "app.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.platform.dns_name
    zone_id                = aws_lb.platform.zone_id
    evaluate_target_health = false
  }
}
