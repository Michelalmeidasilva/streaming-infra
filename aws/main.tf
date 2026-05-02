terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# 1. Provision the S3 Bucket
module "storage_s3" {
  source      = "./modules/storage-s3"
  bucket_name = "vod-streaming-storage-2026-meu-teste" # You can change this to a unique name
}

# 2. Provision the IAM User with least-privilege access to the bucket
module "iam_s3" {
  source     = "./modules/iam-s3"
  user_name  = "vod-storage-svc-teste"
  bucket_arn = module.storage_s3.bucket_arn
}

output "bucket_name" {
  value = module.storage_s3.bucket_name
}

output "iam_access_key_id" {
  value = module.iam_s3.iam_access_key_id
}

output "iam_secret_access_key" {
  value     = module.iam_s3.iam_secret_access_key
  sensitive = true
}
