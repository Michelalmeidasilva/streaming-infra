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
