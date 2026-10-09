terraform {
  required_version = ">= 1.5.7, < 2.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.100.0"
    }
  }
  backend "s3" {
    key = "dev/eks-eso/terraform.tfstate"
  }
}
