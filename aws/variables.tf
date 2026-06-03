variable "aws_region" {
  type        = string
  description = "Região AWS principal de toda a stack."
  default     = "us-east-2"
}

variable "environment" {
  type        = string
  description = "Ambiente (prod, staging, dev)."
  default     = "prod"
}

variable "storage_bucket_name" {
  type        = string
  description = "Nome do bucket S3 EXISTENTE a ser adotado (obtido pela auditoria — Task 2)."
}

variable "cors_allowed_origins" {
  type        = list(string)
  description = "Origens de browser autorizadas a fazer upload direto (presigned)."
  default = [
    "http://localhost:3000",
    "http://127.0.0.1:3000",
  ]
}

variable "iam_user_name" {
  type        = string
  description = "Nome do IAM user de acesso ao bucket (least-privilege)."
  default     = "vod-storage-svc"
}

# --- Segredos para o SSM (valores reais em terraform.tfvars, git-ignored) ---
variable "mongodb_uri" {
  type        = string
  description = "Connection string do MongoDB Atlas."
  sensitive   = true
}

variable "rabbitmq_url" {
  type        = string
  description = "AMQP URL do CloudAMQP."
  sensitive   = true
}

variable "redis_url" {
  type        = string
  description = "URL do Redis externo (cache existente)."
  sensitive   = true
}
