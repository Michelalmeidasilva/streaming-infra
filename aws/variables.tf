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

# --- Benchmark harness (Plano 1 — desligado por padrão) ---

variable "enable_transcode_benchmark_harness" {
  type        = bool
  default     = false
  description = "Ativa o módulo de frota de benchmark (controlado pelo orquestrador)."
}

variable "benchmark_instance_types" {
  type    = list(string)
  default = []
}

variable "benchmark_session_id" {
  type    = string
  default = "00000000-0000-4000-8000-000000000000"
}

variable "benchmark_codecs" {
  type    = list(string)
  default = ["h264"]
}

variable "benchmark_resolutions" {
  type    = string
  default = "1280x720:2800,1920x1080:5000"
}

variable "benchmark_repeats" {
  type    = number
  default = 3
}

variable "benchmark_mode" {
  type    = string
  default = "throughput"
}
