output "iam_access_key_id" {
  description = "The Access Key ID for the IAM User"
  value       = aws_iam_access_key.this.id
}

output "iam_secret_access_key" {
  description = "The Secret Access Key for the IAM User (TREAT AS SENSITIVE)"
  value       = aws_iam_access_key.this.secret
  sensitive   = true
}

output "iam_user_arn" {
  description = "The ARN of the IAM User"
  value       = aws_iam_user.this.arn
}
