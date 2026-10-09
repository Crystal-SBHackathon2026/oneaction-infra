terraform {
  backend "s3" {
    key = "dev/dns/terraform.tfstate"
  }
}
