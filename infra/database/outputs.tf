output "db_subnet_group_name" {
  value = aws_db_subnet_group.this.name
}

output "rds_security_group_id" {
  value = data.terraform_remote_state.network.outputs.rds_security_group_id
}

output "db_instance_identifier" {
  value = aws_db_instance.review.identifier
}

output "db_endpoint" {
  value = aws_db_instance.review.endpoint
}

output "db_master_user_secret_arn" {
  value = try(aws_db_instance.review.master_user_secret[0].secret_arn, null)
}
