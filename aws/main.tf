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
  repository_names = ["vod-ingest", "vod-distribution", "vod-transcode"]
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

# 11. Benchmark harness (Plano 1 — desligado por padrão; ativado pelo orquestrador).
# Nota: ecr_image_gpu usa sufixo "-gpu" construído a partir do repo vod-transcode;
# não há repositório ECR separado para GPU — o tag de imagem distingue CPUs de GPUs.
module "transcode_benchmark_harness" {
  count  = var.enable_transcode_benchmark_harness ? 1 : 0
  source = "./modules/transcode-benchmark-harness"

  benchmark_instance_types = var.benchmark_instance_types
  benchmark_session_id     = var.benchmark_session_id
  codecs                   = var.benchmark_codecs
  resolutions              = var.benchmark_resolutions
  repeats                  = var.benchmark_repeats
  mode                     = var.benchmark_mode

  corpus_bucket        = module.storage_s3.bucket_id
  corpus_prefix        = "benchmark/corpus/"
  ingest_benchmark_url = module.ingest_lambda.function_url

  vpc_id    = module.network.vpc_id
  subnet_id = module.network.public_subnet_ids[0]

  ecr_image_cpu = "${module.ecr.repository_urls["vod-transcode"]}:latest"
  ecr_image_gpu = "${module.ecr.repository_urls["vod-transcode"]}-gpu:latest"
}

# 12. Observability — CloudWatch dashboard + alarms (Plan 2 Phase A).
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
