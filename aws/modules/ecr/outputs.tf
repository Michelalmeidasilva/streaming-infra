output "repository_urls" {
  description = "Mapa nome→URL do repositório ECR."
  value       = { for k, r in aws_ecr_repository.this : k => r.repository_url }
}
