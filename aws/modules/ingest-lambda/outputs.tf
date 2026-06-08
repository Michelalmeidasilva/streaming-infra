output "function_name" {
  value = aws_lambda_function.this.function_name
}

output "function_url" {
  description = "Base pública do ingest (API Gateway HTTP API), com / final para concatenar paths."
  value       = "${trimsuffix(aws_apigatewayv2_stage.this.invoke_url, "/")}/"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.lambda.name
}
