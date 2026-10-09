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
  availability_zones = ["ap-northeast-2a", "ap-northeast-2c"]
  eks_subnet_cidrs   = ["10.0.32.0/19", "10.0.64.0/19"]
}

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "oneaction-vpc" }
}

resource "aws_subnet" "public_2a" {
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.availability_zones[0]
  cidr_block              = "10.0.0.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "oneaction-public-2a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_2c" {
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.availability_zones[1]
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "oneaction-public-2c"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "eks_2a" {
  vpc_id            = aws_vpc.this.id
  availability_zone = local.availability_zones[0]
  cidr_block        = local.eks_subnet_cidrs[0]

  tags = {
    Name                              = "oneaction-private-eks-2a"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/oneaction" = "shared"
  }
}

resource "aws_subnet" "eks_2c" {
  vpc_id            = aws_vpc.this.id
  availability_zone = local.availability_zones[1]
  cidr_block        = local.eks_subnet_cidrs[1]

  tags = {
    Name                              = "oneaction-private-eks-2c"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/oneaction" = "shared"
  }
}

resource "aws_subnet" "data_2a" {
  vpc_id            = aws_vpc.this.id
  availability_zone = local.availability_zones[0]
  cidr_block        = "10.0.10.0/24"
  tags              = { Name = "oneaction-private-data-2a" }
}

resource "aws_subnet" "data_2c" {
  vpc_id            = aws_vpc.this.id
  availability_zone = local.availability_zones[1]
  cidr_block        = "10.0.11.0/24"
  tags              = { Name = "oneaction-private-data-2c" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "oneaction-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "oneaction-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_2a.id

  depends_on = [aws_internet_gateway.this]
  tags       = { Name = "oneaction-nat-2a" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "oneaction-public-rt" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public_2a" {
  subnet_id      = aws_subnet.public_2a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2c" {
  subnet_id      = aws_subnet.public_2c.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "oneaction-private-rt" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each = {
    eks_2a  = aws_subnet.eks_2a.id
    eks_2c  = aws_subnet.eks_2c.id
    data_2a = aws_subnet.data_2a.id
    data_2c = aws_subnet.data_2c.id
  }

  subnet_id      = each.value
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "oneaction-s3-endpoint" }
}

resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "Public HTTP and HTTPS ingress for oneaction ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "alb-sg" }
}

resource "aws_security_group" "eks_node_extra" {
  name        = "eks-node-extra-sg"
  description = "Additional EKS node SG allowing traffic from the platform ALB"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "All traffic from ALB"
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "eks-node-extra-sg" }
}

resource "aws_security_group" "rds" {
  name        = "rds-sg"
  description = "PostgreSQL access from oneaction EKS private subnets"
  vpc_id      = aws_vpc.this.id

  dynamic "ingress" {
    for_each = toset(local.eks_subnet_cidrs)
    content {
      description = "PostgreSQL from EKS subnet ${ingress.value}"
      from_port   = 5432
      to_port     = 5432
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "rds-sg" }
}
