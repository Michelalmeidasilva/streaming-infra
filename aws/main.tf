# 1. Bucket S3 existente (adotado via import — Task 7). Config descreve o estado desejado.
module "storage_s3" {
  source               = "./modules/storage-s3"
  bucket_name          = var.storage_bucket_name
  environment          = var.environment
  cors_allowed_origins = var.cors_allowed_origins
}

# 2. IAM user least-privilege para o bucket.
module "iam_s3" {
  source     = "./modules/iam-s3"
  user_name  = var.iam_user_name
  bucket_arn = module.storage_s3.bucket_arn
}

# 3. Rede mínima (usada pelo transcode-batch no Plano 2).
module "network" {
  source      = "./modules/network"
  environment = var.environment
}

# 4. Secrets no SSM Parameter Store (lidos em runtime por Lambda/Batch).
module "ssm_secrets" {
  source      = "./modules/ssm-secrets"
  environment = var.environment

  mongodb_uri  = var.mongodb_uri
  rabbitmq_url = var.rabbitmq_url
  redis_url    = var.redis_url

  s3_access_key_id     = module.iam_s3.iam_access_key_id
  s3_secret_access_key = module.iam_s3.iam_secret_access_key
}

# 5. ECR — repositórios de imagem para os 3 serviços container.
module "ecr" {
  source           = "./modules/ecr"
  repository_names = ["vod-ingest", "vod-distribution", "vod-transcode", "vod-transcode-gpu", "vod-benchmark-orchestrator"]
}

# 6. Lambda do ingest (Event Gateway).
module "ingest_lambda" {
  source              = "./modules/ingest-lambda"
  function_name       = "streaming-ingest"
  image_uri           = "${module.ecr.repository_urls["vod-ingest"]}:latest"
  storage_bucket_name = module.storage_s3.bucket_id
  ssm_parameter_arns  = module.ssm_secrets.parameter_arns

  mongodb_uri  = var.mongodb_uri
  rabbitmq_url = var.rabbitmq_url
}

output "ingest_function_url" {
  value = module.ingest_lambda.function_url
}

# 7. Lambda do distribution (read-only, cache-aside) + CloudFront.
module "distribution_lambda" {
  source              = "./modules/distribution-lambda"
  function_name       = "streaming-distribution"
  image_uri           = "${module.ecr.repository_urls["vod-distribution"]}:latest"
  storage_bucket_name = module.storage_s3.bucket_id
  ssm_parameter_arns  = module.ssm_secrets.parameter_arns

  mongodb_uri          = var.mongodb_uri
  redis_url            = var.redis_url
  s3_access_key_id     = module.iam_s3.iam_access_key_id
  s3_secret_access_key = module.iam_s3.iam_secret_access_key
}

output "distribution_cdn_domain" {
  value = module.distribution_lambda.cdn_domain
}

# 8. Batch Fargate Spot para o transcode.
module "transcode_batch" {
  source               = "./modules/transcode-batch"
  environment          = var.environment
  image_uri            = "${module.ecr.repository_urls["vod-transcode"]}:latest"
  subnet_ids           = module.network.public_subnet_ids
  security_group_id    = module.network.batch_security_group_id
  storage_bucket_name  = module.storage_s3.bucket_id
  ssm_parameter_prefix = module.ssm_secrets.parameter_prefix
  ssm_parameter_arns   = module.ssm_secrets.parameter_arns
  aws_region           = var.aws_region
  # Function URL do ingest termina em "/"; o serviço posta em <base>/events e
  # <base>/upload-state/videos/:id, então a base inclui o sufixo /api/v1.
  event_gateway_url = "${module.ingest_lambda.function_url}api/v1"
}

# 9. EventBridge: S3→Batch (transcode) + S3→ingest (API Destination).
module "events" {
  source                   = "./modules/events"
  environment              = var.environment
  bucket_name              = module.storage_s3.bucket_id
  ingest_function_url      = module.ingest_lambda.function_url
  batch_job_queue_arn      = module.transcode_batch.job_queue_arn
  batch_job_definition_arn = module.transcode_batch.job_definition_arn
}

# 10. Web-client: bucket S3 privado + CloudFront OAC.
module "web_client_cdn" {
  source      = "./modules/web-client-cdn"
  environment = var.environment
  bucket_name = "vod-web-client-${var.environment}-use2"
}

output "web_client_cdn_domain" {
  value = module.web_client_cdn.cdn_domain
}

output "bucket_name" {
  value = module.storage_s3.bucket_id
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "iam_access_key_id" {
  value = module.iam_s3.iam_access_key_id
}

# 11. Observability — CloudWatch dashboard + alarms (Plan 2 Phase A).
module "observability" {
  source    = "./modules/observability"
  providers = { aws.us_east_1 = aws.us_east_1 }

  environment = var.environment
  aws_region  = var.aws_region

  lambda_function_names      = ["streaming-ingest", "streaming-distribution"]
  lambda_log_group_names     = [module.ingest_lambda.log_group_name, module.distribution_lambda.log_group_name]
  cloudfront_distribution_id = module.distribution_lambda.cdn_distribution_id
  batch_log_group_name       = module.transcode_batch.log_group_name
}

output "observability_dashboard" {
  value = module.observability.dashboard_name
}

# 12. Cost guard — budgets ($40/mês, $3/dia) → SNS → kill-switch Lambda (soft-stop).
module "cost_guard" {
  source    = "./modules/cost-guard"
  providers = { aws = aws.us_east_1 }

  environment   = var.environment
  target_region = var.aws_region

  monthly_limit_usd = var.monthly_limit_usd
  daily_limit_usd   = var.daily_limit_usd
  alert_email       = var.alert_email

  lambda_function_names = ["streaming-ingest", "streaming-distribution"]
  event_rule_names = [
    module.events.s3_to_batch_rule_name,
    module.events.s3_to_ingest_rule_name,
  ]
  batch_job_queue_name = module.transcode_batch.job_queue_name
  cloudfront_distribution_ids = [
    module.distribution_lambda.cdn_distribution_id,
    module.web_client_cdn.cdn_distribution_id,
  ]
}

output "cost_guard_killswitch_function" {
  value = module.cost_guard.killswitch_function_name
}

# 13. Transcode benchmark harness — self-terminating EC2, corpus-driven.
# Disabled by default; enable with enable_transcode_benchmark_harness=true.
# Upload clips to s3://<bucket>/benchmark/corpus/, then apply.
# The instance runs the benchmark binary over the corpus matrix and self-terminates.
module "transcode_benchmark_harness" {
  source = "./modules/transcode-benchmark-harness"

  enabled        = var.enable_transcode_benchmark_harness
  instance_type  = var.benchmark_instance_type
  instance_types = var.benchmark_instance_types
  ami_arch       = var.benchmark_ami_arch
  machine_label  = var.benchmark_machine_label

  gpu                  = var.benchmark_gpu
  encoder_backend      = var.benchmark_gpu ? "nvenc" : "software"
  image_uri            = var.benchmark_gpu ? "${module.ecr.repository_urls["vod-transcode-gpu"]}:${var.benchmark_image_tag}" : "${module.ecr.repository_urls["vod-transcode"]}:${var.benchmark_image_tag}"
  subnet_id            = module.network.public_subnet_ids[0]
  security_group_id    = module.network.batch_security_group_id
  aws_region           = var.aws_region
  corpus_bucket        = module.storage_s3.bucket_id
  corpus_prefix        = var.benchmark_corpus_prefix
  codecs               = var.benchmark_codecs
  resolutions          = var.benchmark_resolutions
  repeats              = var.benchmark_repeats
  ingest_benchmark_url = "${module.ingest_lambda.function_url}api/v1"
  ssm_parameter_prefix = module.ssm_secrets.parameter_prefix
  ssm_parameter_arns   = module.ssm_secrets.parameter_arns
  benchmark_mode       = var.benchmark_mode
  quality_points       = var.benchmark_quality_points
  tags                 = { Environment = var.environment }
}

output "benchmark_instance_id" {
  value       = module.transcode_benchmark_harness.instance_id
  description = "EC2 benchmark harness instance ID (null when disabled)."
}

# 14. Benchmark trigger — Lambda orquestrador (AuthType=AWS_IAM) + watchdog.
# Count-gated: sem recursos adicionais quando a flag está false.
module "benchmark_trigger" {
  count  = var.enable_transcode_benchmark_harness ? 1 : 0
  source = "./modules/benchmark-trigger"

  image_uri                      = "${module.ecr.repository_urls["vod-benchmark-orchestrator"]}:latest"
  benchmark_instance_profile_arn = module.transcode_benchmark_harness.instance_profile_arn
  benchmark_role_arn             = module.transcode_benchmark_harness.instance_role_arn
  benchmark_subnet_id            = module.network.public_subnet_ids[0]
  state_bucket                   = "vod-tfstate-prod-use2"
  corpus_bucket                  = module.storage_s3.bucket_id
  allowed_instance_types         = var.benchmark_instance_types
}

# Permite ao vod-storage-svc invocar a Function URL do orquestrador via SigV4 IAM.
# Identidade compartilhada — hardening futuro: identidade dedicada ao orquestrador.
resource "aws_iam_user_policy" "benchmark_invoke" {
  count = var.enable_transcode_benchmark_harness ? 1 : 0
  name  = "vod-benchmark-invoke"
  user  = module.iam_s3.user_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "InvokeBenchmarkOrchestrator"
      Effect    = "Allow"
      Action    = "lambda:InvokeFunctionUrl"
      Resource  = try(module.benchmark_trigger[0].function_arn, "")
      Condition = { StringEquals = { "lambda:FunctionUrlAuthType" = "AWS_IAM" } }
    }]
  })
}

output "benchmark_function_url" {
  value       = try(module.benchmark_trigger[0].function_url, null)
  description = "URL da Function URL do orquestrador (null quando flag desabilitada)."
}

output "benchmark_function_arn" {
  value       = try(module.benchmark_trigger[0].function_arn, null)
  description = "ARN da Lambda do orquestrador (null quando flag desabilitada)."
}
