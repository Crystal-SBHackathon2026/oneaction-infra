output "alb_dns_name" {
  value = aws_lb.platform.dns_name
}

output "alb_arn_suffix" {
  value = aws_lb.platform.arn_suffix
}

output "platform_target_group_arn" {
  value = aws_lb_target_group.platform.arn
}

output "app_url" {
  value = length(aws_route53_record.app) == 0 ? null : "https://${aws_route53_record.app[0].fqdn}"
}
