variable "function_name" {
  type    = string
  default = "streaming-distribution"
}

variable "image_uri" {
  type = string
}

variable "storage_bucket_name" {
  type = string
}

variable "ssm_parameter_arns" {
  type = list(string)
}

variable "mongodb_uri" {
  type      = string
  sensitive = true
}
variable "redis_url" {
  type      = string
  sensitive = true
}
variable "s3_access_key_id" {
  type      = string
  sensitive = true
}
variable "s3_secret_access_key" {
  type      = string
  sensitive = true
}
