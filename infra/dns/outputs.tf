output "hosted_zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "hosted_zone_name_servers" {
  description = "Delegate these name servers from the parent domain. ACM validation remains pending until delegation works."
  value       = aws_route53_zone.this.name_servers
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "domain_name" {
  value = var.domain_name
}
