output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [aws_subnet.public_2a.id, aws_subnet.public_2c.id]
}

output "private_eks_subnet_ids" {
  value = [aws_subnet.eks_2a.id, aws_subnet.eks_2c.id]
}

output "private_data_subnet_ids" {
  value = [aws_subnet.data_2a.id, aws_subnet.data_2c.id]
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this.id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "eks_node_extra_security_group_id" {
  value = aws_security_group.eks_node_extra.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}
