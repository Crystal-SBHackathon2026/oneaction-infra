terraform {
  backend "s3" {
    key = "dev/eks/terraform.tfstate"
  }
}
