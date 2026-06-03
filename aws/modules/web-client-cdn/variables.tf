variable "environment" {
  type    = string
  default = "prod"
}

variable "bucket_name" {
  type        = string
  description = "Nome do bucket do site (globalmente único)."
}
