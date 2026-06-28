variable "environment" {
  type        = string
  description = "Ambiente (prod, staging, dev)."
}

variable "target_region" {
  type        = string
  description = "Região onde vivem Lambda/EventBridge/Batch alvo (us-east-2)."
}

variable "monthly_limit_usd" {
  type        = number
  description = "Teto mensal de gasto em USD. Kill-switch dispara em 100% actual."
}

variable "daily_limit_usd" {
  type        = number
  description = "Teto diário de gasto em USD. Kill-switch dispara em 100% actual."
}

variable "alert_email" {
  type        = string
  description = "E-mail que recebe alertas de budget e confirmação do kill-switch."
}

variable "lambda_function_names" {
  type        = list(string)
  description = "Funções Lambda a ter a concorrência zerada."
}

variable "event_rule_names" {
  type        = list(string)
  description = "Regras EventBridge a desabilitar."
}

variable "batch_job_queue_name" {
  type        = string
  description = "Batch job queue a desabilitar."
}

variable "cloudfront_distribution_ids" {
  type        = list(string)
  description = "Distribuições CloudFront a desabilitar."
}
