variable "user_name" {
  type        = string
  description = "Name of the IAM User"
  default     = "vod-storage-svc"
}

variable "bucket_arn" {
  type        = string
  description = "The ARN of the S3 bucket to grant access to"
}
