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

output "bucket_name" {
  value = module.storage_s3.bucket_id
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "iam_access_key_id" {
  value = module.iam_s3.iam_access_key_id
}
