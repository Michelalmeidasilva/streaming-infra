variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket. Must be globally unique."
}

variable "environment" {
  type        = string
  description = "Environment (e.g., dev, staging, prod)"
  default     = "dev"
}
