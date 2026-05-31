variable "bucket_name" {
  type        = string
  description = "Name of the S3 bucket. Must be globally unique."
}

variable "environment" {
  type        = string
  description = "Environment (e.g., dev, staging, prod)"
  default     = "dev"
}

variable "cors_allowed_origins" {
  type        = list(string)
  description = "Browser origins allowed to upload directly to the bucket via presigned URLs."
  default = [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
  ]
}

variable "cors_allowed_headers" {
  type        = list(string)
  description = "Request headers allowed by the bucket CORS policy."
  default     = ["*"]
}

variable "cors_expose_headers" {
  type        = list(string)
  description = "Response headers exposed to browser clients."
  default     = ["ETag"]
}
