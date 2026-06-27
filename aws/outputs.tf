output "benchmark_instance_profile_arn" {
  description = "ARN do instance profile do harness (para PassRole do orquestrador — Plano 2). Null quando o harness está desligado."
  value       = var.enable_transcode_benchmark_harness ? module.transcode_benchmark_harness[0].instance_profile_arn : null
}
