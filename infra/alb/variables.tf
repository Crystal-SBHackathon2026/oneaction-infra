variable "aws_profile" {
  type    = string
  default = ""
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "owner" {
  type    = string
  default = "hyeyeon.kim"
}

variable "certificate_arn" {
  description = "ACM certificate ARN from the dns stack. Leave empty until a real domain is available."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID from the dns stack."
  type        = string
  default     = ""
}

variable "domain_name" {
  description = "Delegated domain from the dns stack."
  type        = string
  default     = ""
}
