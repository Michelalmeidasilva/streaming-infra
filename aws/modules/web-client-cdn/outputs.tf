output "bucket_name" {
  value = aws_s3_bucket.site.id
}

output "cdn_domain" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "cdn_distribution_id" {
  description = "ID da distribuição CloudFront do web-client (alvo do kill-switch)."
  value       = aws_cloudfront_distribution.site.id
}
