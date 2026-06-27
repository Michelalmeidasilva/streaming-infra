output "benchmark_instance_profile_arn" {
  description = "ARN do instance profile do harness (para PassRole do orquestrador — Plano 2). Null quando o harness está desligado."
  value       = var.enable_transcode_benchmark_harness ? module.transcode_benchmark_harness[0].instance_profile_arn : null
}

output "benchmark_function_url" {
  description = "Function URL do orquestrador Lambda (requer SigV4 IAM — Plano 3). Null quando o trigger está desligado."
  value       = var.enable_transcode_benchmark_harness ? module.benchmark_trigger[0].function_url : null
}

output "benchmark_function_arn" {
  description = "ARN da função Lambda do orquestrador (para políticas IAM de invoke — Plano 3). Null quando o trigger está desligado."
  value       = var.enable_transcode_benchmark_harness ? module.benchmark_trigger[0].function_arn : null
}
