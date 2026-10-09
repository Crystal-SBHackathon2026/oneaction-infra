output "cluster_arn" {
  value = aws_msk_cluster.this.arn
}

output "bootstrap_brokers" {
  description = "PLAINTEXT bootstrap string (port 9092) for KAFKA_BOOTSTRAP."
  value       = aws_msk_cluster.this.bootstrap_brokers
}

output "security_group_id" {
  value = aws_security_group.msk.id
}
