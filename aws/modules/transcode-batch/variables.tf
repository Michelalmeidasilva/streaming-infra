variable "environment" {
  type    = string
  default = "prod"
}

variable "image_uri" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "storage_bucket_name" {
  type = string
}

variable "ssm_parameter_prefix" {
  type        = string
  description = "Prefixo SSM, ex: /vod/prod"
}

variable "ssm_parameter_arns" {
  type = list(string)
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}
