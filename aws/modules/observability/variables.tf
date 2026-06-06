variable "environment" { type = string }
variable "aws_region" { type = string }

variable "lambda_function_names" {
  type        = list(string)
  description = "Lambda function names to monitor (ingest, distribution)."
}

variable "lambda_log_group_names" {
  type        = list(string)
  description = "CloudWatch log group names for the lambdas (parallel to lambda_function_names)."
}

variable "cloudfront_distribution_id" {
  type        = string
  description = "Distribution serving the web client / manifests (signal 6 traffic, 4 5xx)."
}

variable "batch_log_group_name" {
  type        = string
  description = "transcode-batch CloudWatch log group."
}

variable "error_rate_threshold" {
  type    = number
  default = 1
}

variable "p95_latency_ms_threshold" {
  type    = number
  default = 3000
}

variable "alarm_sns_topic_arn" {
  type    = string
  default = ""
}
