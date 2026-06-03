output "state_bucket_name" {
  description = "Nome do bucket de state — usar em aws/backend.tf."
  value       = aws_s3_bucket.tfstate.id
}
