output "s3_to_batch_rule_name" {
  description = "Nome da regra EventBridge S3→Batch (alvo do kill-switch)."
  value       = aws_cloudwatch_event_rule.s3_to_batch.name
}

output "s3_to_ingest_rule_name" {
  description = "Nome da regra EventBridge S3→ingest (alvo do kill-switch)."
  value       = aws_cloudwatch_event_rule.s3_to_ingest.name
}
