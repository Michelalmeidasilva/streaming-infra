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

# --- Cost guard (kill-switch por budget) ---
variable "monthly_limit_usd" {
  type        = number
  description = "Teto mensal de gasto em USD (dispara kill-switch em 100% actual)."
  default     = 40
}

variable "daily_limit_usd" {
  type        = number
  description = "Teto diário de gasto em USD (dispara kill-switch em 100% actual)."
  default     = 3
}

variable "alert_email" {
  type        = string
  description = "E-mail que recebe alertas de budget e confirmação do kill-switch."
}

# --- Transcode benchmark harness (corpus-driven, self-terminating, off by default) ---
variable "enable_transcode_benchmark_harness" {
  description = "Spin up the self-terminating corpus-driven benchmark harness EC2 instance."
  type        = bool
  default     = false
}

variable "benchmark_instance_type" {
  description = "EC2 instance type for the transcode benchmark run (e.g. c5.xlarge for x86_64, c7g.xlarge for Graviton arm64)."
  type        = string
  default     = "c5.xlarge"
}

variable "benchmark_machine_label" {
  description = "Run label for the benchmark instance. Defaults to the instance type when empty."
  type        = string
  default     = ""
}

variable "benchmark_ami_arch" {
  description = "CPU architecture for the benchmark AMI and instance: x86_64 or arm64 (Graviton). Must match the architecture of the image referenced by benchmark_image_tag."
  type        = string
  default     = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.benchmark_ami_arch)
    error_message = "benchmark_ami_arch must be \"x86_64\" or \"arm64\"."
  }
}

variable "benchmark_image_tag" {
  description = "ECR tag of the vod-transcode image the benchmark instance runs. Use a tag whose architecture matches benchmark_ami_arch (e.g. a multi-arch \"latest\", or a dedicated \"arm64\")."
  type        = string
  default     = "latest"
}

variable "benchmark_corpus_prefix" {
  description = "S3 key prefix where benchmark corpus clips live (e.g. benchmark/corpus/)."
  type        = string
  default     = "benchmark/corpus/"
}

variable "benchmark_codecs" {
  description = "Comma-separated list of codecs the benchmark matrix exercises."
  type        = string
  default     = "h264,h265,av1"
}

variable "benchmark_resolutions" {
  description = "Comma-separated WxH:bitrate pairs for the benchmark resolution ladder."
  type        = string
  default     = "1280x720:3000,1920x1080:6000"
}

variable "benchmark_repeats" {
  description = "Number of times each corpus clip is re-encoded per codec/resolution combination."
  type        = number
  default     = 3
}
