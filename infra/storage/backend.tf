terraform {
  backend "s3" {
    key = "dev/storage/terraform.tfstate"
  }
}
