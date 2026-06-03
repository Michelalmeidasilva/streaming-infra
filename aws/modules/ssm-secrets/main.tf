locals {
  prefix = "/vod/${var.environment}"
}

resource "aws_ssm_parameter" "mongodb_uri" {
  name  = "${local.prefix}/MONGODB_URI"
  type  = "SecureString"
  value = var.mongodb_uri
}

resource "aws_ssm_parameter" "rabbitmq_url" {
  name  = "${local.prefix}/RABBITMQ_URL"
  type  = "SecureString"
  value = var.rabbitmq_url
}

resource "aws_ssm_parameter" "redis_url" {
  name  = "${local.prefix}/REDIS_URL"
  type  = "SecureString"
  value = var.redis_url
}

resource "aws_ssm_parameter" "s3_access_key_id" {
  name  = "${local.prefix}/S3_ACCESS_KEY_ID"
  type  = "SecureString"
  value = var.s3_access_key_id
}

resource "aws_ssm_parameter" "s3_secret_access_key" {
  name  = "${local.prefix}/S3_SECRET_ACCESS_KEY"
  type  = "SecureString"
  value = var.s3_secret_access_key
}
