variable "function_name" {
  type    = string
  default = "streaming-ingest"
}

variable "image_uri" {
  type        = string
  description = "URI da imagem ECR (com tag), ex: <repo>:latest"
}

variable "storage_bucket_name" {
  type = string
}

variable "ssm_parameter_arns" {
  type        = list(string)
  description = "ARNs dos SSM params que a função pode ler."
}

# Valores sensíveis injetados como env do Lambda (o app lê env vars diretamente).
variable "mongodb_uri" {
  type      = string
  sensitive = true
}
variable "rabbitmq_url" {
  type      = string
  sensitive = true
}
