output "instance_profile_arn" {
  description = "ARN do instance profile (para PassRole do orquestrador)."
  value       = aws_iam_instance_profile.benchmark.arn
}

output "instance_role_arn" {
  description = "ARN da role da EC2 de benchmark."
  value       = aws_iam_role.benchmark.arn
}
