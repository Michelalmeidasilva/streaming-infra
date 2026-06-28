output "job_queue_arn" {
  value = aws_batch_job_queue.this.arn
}

output "job_definition_arn" {
  value = aws_batch_job_definition.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group for transcode-batch jobs."
  value       = aws_cloudwatch_log_group.this.name
}

output "job_queue_name" {
  description = "Nome da Batch job queue (alvo do kill-switch)."
  value       = aws_batch_job_queue.this.name
}
