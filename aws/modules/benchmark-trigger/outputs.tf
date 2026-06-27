output "function_url" {
  description = "URL da Function URL do orquestrador (requer SigV4 IAM)."
  value       = aws_lambda_function_url.orchestrator.function_url
}

output "function_name" {
  description = "Nome da função Lambda do orquestrador."
  value       = aws_lambda_function.orchestrator.function_name
}

output "function_arn" {
  description = "ARN da função Lambda do orquestrador."
  value       = aws_lambda_function.orchestrator.arn
}

output "orchestrator_role_arn" {
  description = "ARN da IAM role do orquestrador (para conceder invoke via SigV4)."
  value       = aws_iam_role.orchestrator.arn
}
