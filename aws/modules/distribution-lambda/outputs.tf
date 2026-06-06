output "function_url" {
  value = aws_lambda_function_url.this.function_url
}

output "cdn_domain" {
  description = "Domínio CloudFront — vira PUBLIC_DISTRIBUTION_URL do web-client."
  value       = "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.lambda.name
}

output "cdn_distribution_id" {
  description = "CloudFront distribution ID (used by observability alarms/dashboard)."
  value       = aws_cloudfront_distribution.this.id
}
