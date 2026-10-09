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

variable "notification_email" {
  description = "Optional SNS email endpoint. The recipient must confirm the subscription."
  type        = string
  default     = ""
}

variable "alb_5xx_threshold" {
  type        = number
  default     = 5
  description = "ELB-generated 5XX responses per minute."
}

variable "rds_free_storage_threshold_bytes" {
  type        = number
  default     = 4294967296
  description = "4 GiB, or 20 percent of the initial 20 GiB RDS allocation."
}
