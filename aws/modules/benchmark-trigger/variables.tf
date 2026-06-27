variable "image_uri" {
  type        = string
  description = "URI da imagem ECR do orquestrador Lambda."
}

variable "benchmark_instance_profile_arn" {
  type        = string
  description = "ARN do instance profile do harness (output do Plano 1). Usado para escopar o iam:PassRole."
}

variable "benchmark_subnet_id" {
  type        = string
  description = "Subnet ID onde as instâncias de benchmark serão lançadas."
}

variable "state_bucket" {
  type        = string
  description = "Nome do bucket S3 que armazena o state Terraform do benchmark."
}

variable "corpus_bucket" {
  type        = string
  description = "Nome do bucket S3 que contém o corpus de vídeos para benchmark."
}

variable "allowed_instance_types" {
  type        = list(string)
  description = "Lista de tipos de instância EC2 permitidos pelo orquestrador (allowlist de segurança)."
}

variable "ttl_hours" {
  type        = number
  default     = 2
  description = "TTL em horas das instâncias de benchmark. O watchdog termina instâncias mais antigas."
}

variable "name_prefix" {
  type        = string
  default     = "vod-bench-trigger"
  description = "Prefixo para nomear recursos IAM, Lambda e EventBridge."
}
