variable "aws_profile" {
  description = "AWS CLI profile, or empty when using exported temporary credentials."
  type        = string
  default     = ""
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-2"

  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "The oneaction project uses the Seoul Region ap-northeast-2."
  }
}

variable "owner" {
  type    = string
  default = "hyeyeon.kim"
}

variable "kafka_version" {
  description = "MSK Kafka version. Check `aws kafka list-kafka-versions` before changing."
  type        = string
  default     = "3.9.x"
}

variable "broker_volume_size" {
  description = "EBS storage per broker in GiB."
  type        = number
  default     = 20
}
