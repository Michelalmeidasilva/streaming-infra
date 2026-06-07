variable "environment" {
  type    = string
  default = "prod"
}

variable "image_uri" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "security_group_id" {
  type = string
}

variable "storage_bucket_name" {
  type = string
}

variable "ssm_parameter_prefix" {
  type        = string
  description = "Prefixo SSM, ex: /vod/prod"
}

variable "event_gateway_url" {
  type        = string
  description = "Base URL do Event Gateway (ingest) que o job usa para persistir o resultado, incluindo o sufixo /api/v1. Ex: https://<id>.lambda-url.us-east-2.on.aws/api/v1"
}

variable "ssm_parameter_arns" {
  type = list(string)
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "create_batch_service_linked_role" {
  type        = bool
  description = "Cria o SLR AWSServiceRoleForBatch. Defina false se ele já existir na conta."
  default     = true
}
