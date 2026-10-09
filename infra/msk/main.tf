provider "aws" {
  profile             = var.aws_profile == "" ? null : var.aws_profile
  region              = var.aws_region
  allowed_account_ids = ["123456789012"]

  default_tags {
    tags = {
      Project = "oneaction"
      Owner   = var.owner
      Env     = "dev"
    }
  }
}

locals {
  cluster_name = "oneaction-review"
  remote_state_config = {
    bucket         = "oneaction-tfstate-123456789012"
    region         = var.aws_region
    dynamodb_table = "oneaction-terraform-locks"
    encrypt        = true
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config  = merge(local.remote_state_config, { key = "dev/network/terraform.tfstate" })
}

# Client CIDRs come from the EKS subnets so pods (VPC CNI IPs) can reach the brokers.
data "aws_subnet" "eks" {
  for_each = toset(data.terraform_remote_state.network.outputs.private_eks_subnet_ids)
  id       = each.value
}

resource "aws_security_group" "msk" {
  name        = "msk-sg"
  description = "Kafka PLAINTEXT from oneaction private EKS subnets only"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    description = "Kafka PLAINTEXT from private EKS subnets"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = sort([for subnet in data.aws_subnet.eks : subnet.cidr_block])
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "msk-sg" }
}

# Two brokers: replication factor 2 and min ISR 1 keep producers writable while one broker is down.
resource "aws_msk_configuration" "this" {
  name           = "${local.cluster_name}-config"
  kafka_versions = [var.kafka_version]

  server_properties = <<-PROPERTIES
    auto.create.topics.enable=true
    default.replication.factor=2
    min.insync.replicas=1
    num.partitions=3
    offsets.topic.replication.factor=2
    transaction.state.log.replication.factor=2
    transaction.state.log.min.isr=1
  PROPERTIES

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_msk_cluster" "this" {
  cluster_name           = local.cluster_name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = 2

  broker_node_group_info {
    instance_type   = "kafka.t3.small"
    client_subnets  = data.terraform_remote_state.network.outputs.private_data_subnet_ids
    security_groups = [aws_security_group.msk.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_volume_size
      }
    }
  }

  # VPC-internal only: no client authentication, plaintext client traffic.
  client_authentication {
    unauthenticated = true
  }

  encryption_info {
    encryption_in_transit {
      client_broker = "PLAINTEXT"
      in_cluster    = true
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.this.arn
    revision = aws_msk_configuration.this.latest_revision
  }

  tags = { Name = local.cluster_name }
}
