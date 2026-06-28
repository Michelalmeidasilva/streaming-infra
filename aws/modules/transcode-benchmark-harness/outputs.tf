output "instance_id" {
  value       = try(aws_instance.benchmark[0].id, null)
  description = "Benchmark harness instance ID (null when disabled)."
}
