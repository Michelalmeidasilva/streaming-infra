output "instance_id" {
  value       = try(aws_instance.benchmark[0].id, null)
  description = "ID of the benchmark EC2 instance (null when disabled)."
}

output "machine_label" {
  value       = local.machine_label
  description = "Machine label recorded on transcode runs from this instance."
}

output "instance_public_ip" {
  value       = try(aws_instance.benchmark[0].public_ip, null)
  description = "Public IP of the benchmark instance (null when disabled)."
}
