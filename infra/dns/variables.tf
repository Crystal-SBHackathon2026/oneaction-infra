variable "aws_profile" {
  type    = string
  default = ""
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "domain_name" {
  description = "Full delegated public zone, for example demo.example.com. No placeholder default is provided intentionally."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a real fully qualified domain name without a trailing dot."
  }
}

variable "owner" {
  type    = string
  default = "hyeyeon.kim"
}
