output "parameter_arns" {
  description = "ARNs de todos os parâmetros (para policies de leitura no Plano 2)."
  value = [
    aws_ssm_parameter.mongodb_uri.arn,
    aws_ssm_parameter.rabbitmq_url.arn,
    aws_ssm_parameter.redis_url.arn,
    aws_ssm_parameter.s3_access_key_id.arn,
    aws_ssm_parameter.s3_secret_access_key.arn,
  ]
}

output "parameter_prefix" {
  value = local.prefix
}
