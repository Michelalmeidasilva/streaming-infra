terraform {
  required_version = ">= 1.9.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Provider principal — toda a stack vive em us-east-2 (decisão D6).
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "vod-streaming"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Alias us-east-1 — exigido por CloudFront/ACM (usado nos planos seguintes).
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}
