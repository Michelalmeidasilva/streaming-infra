resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}

# Block all public access for security
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Allow CORS for direct browser uploads (Multipart via Presigned URLs)
resource "aws_s3_bucket_cors_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_headers = var.cors_allowed_headers
    allowed_methods = ["PUT", "POST", "GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    expose_headers  = var.cors_expose_headers # ETag is CRITICAL for the client to read when completing Multipart Uploads
    max_age_seconds = 3000
  }
}

# Enable encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Disable versioning by default to save costs
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Suspended"
  }
}

# Lifecycle configuration for cost reduction
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  # Rule 1: Transition transcoded videos to Infrequent Access after 60 days
  rule {
    id     = "Transition-Transcoded-Videos-To-IA"
    status = "Enabled"

    filter {
      prefix = "transcoded/"
    }

    transition {
      days          = 60
      storage_class = "STANDARD_IA"
    }
  }

  # Rule 2: Expire/Delete raw original videos after 90 days
  rule {
    id     = "Expire-Raw-Videos"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    expiration {
      days = 90
    }
    
    # Optional: If you prefer to store in Deep Archive instead of deleting,
    # comment the `expiration` block above and uncomment the block below:
    # transition {
    #   days          = 90
    #   storage_class = "DEEP_ARCHIVE"
    # }
  }
}
