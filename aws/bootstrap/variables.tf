variable "state_bucket_name" {
  type        = string
  description = "Nome globalmente único do bucket de state."
  default     = "vod-tfstate-prod-use2"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}
