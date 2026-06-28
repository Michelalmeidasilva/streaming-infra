output "instance_id" {
  value       = try(values(aws_instance.benchmark)[0].id, null)
  description = "Benchmark harness instance ID (lexicographically-first instance; null when disabled). For fleet runs, use instance_ids."
}

output "instance_ids" {
  value       = { for k, v in aws_instance.benchmark : k => v.id }
  description = "Map of instance_type -> instance ID for fleet runs (empty map when disabled)."
}
