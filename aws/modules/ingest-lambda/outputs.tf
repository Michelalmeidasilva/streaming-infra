output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_url" {
  description = "URL pública da Function URL (base do webhook)."
  value       = aws_lambda_function_url.this.function_url
}
