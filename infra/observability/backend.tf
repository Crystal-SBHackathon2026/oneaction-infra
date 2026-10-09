terraform {
  backend "s3" {
    key = "dev/observability/terraform.tfstate"
  }
}
