terraform {
  backend "s3" {
    key = "dev/network/terraform.tfstate"
  }
}
