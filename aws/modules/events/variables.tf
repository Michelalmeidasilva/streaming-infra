variable "environment" {
  type    = string
  default = "prod"
}

variable "bucket_name" {
  type = string
}

variable "ingest_function_url" {
  type        = string
  description = "Function URL do ingest (base do webhook)."
}

variable "batch_job_queue_arn" {
  type = string
}

variable "batch_job_definition_arn" {
  type = string
}
