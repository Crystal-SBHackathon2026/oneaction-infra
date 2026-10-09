terraform {
  backend "s3" {
    key = "dev/msk/terraform.tfstate"
  }
}
