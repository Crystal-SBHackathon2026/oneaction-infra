variable "aws_profile" {
  description = "AWS CLI profile used by the provider."
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "Project Region."
  type        = string
  default     = "ap-northeast-2"
}

variable "owner" {
  type    = string
  default = "hyeyeon.kim"
}
