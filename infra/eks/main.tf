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

data "aws_partition" "current" {}

locals {
  cluster_name = "oneaction"
  remote_state_config = {
    bucket         = "oneaction-tfstate-123456789012"
    region         = var.aws_region
    dynamodb_table = "oneaction-terraform-locks"
    encrypt        = true
  }
  node_tags = {
    Name    = "${local.cluster_name}-eks-node"
    Project = "oneaction"
    Owner   = var.owner
    Env     = "dev"
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config  = merge(local.remote_state_config, { key = "dev/network/terraform.tfstate" })
}

data "terraform_remote_state" "observability" {
  backend = "s3"
  config  = merge(local.remote_state_config, { key = "dev/observability/terraform.tfstate" })
}

data "aws_subnet" "eks" {
  for_each = toset(data.terraform_remote_state.network.outputs.private_eks_subnet_ids)
  id       = each.value
}

data "aws_security_group" "node_extra" {
  id = data.terraform_remote_state.network.outputs.eks_node_extra_security_group_id
}

# Verify the observability-owned group exists; do not import or recreate it here.
data "aws_cloudwatch_log_group" "eks" {
  name = data.terraform_remote_state.observability.outputs.eks_log_group_name
}
