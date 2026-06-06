data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.function_name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "basic" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "this" {
  function_name = var.function_name
  package_type  = "Image"
  image_uri     = var.image_uri
  role          = aws_iam_role.this.arn
  timeout       = 15
  memory_size   = 256
  depends_on    = [aws_cloudwatch_log_group.lambda]

  environment {
    variables = {
      STORAGE_PROVIDER      = "s3"
      STORAGE_BUCKET        = var.storage_bucket_name
      TRANSCODED_PREFIX     = "transcoded"
      AWS_LWA_PORT          = "8082"
      MONGODB_URI           = var.mongodb_uri
      REDIS_URL             = var.redis_url
      AWS_ACCESS_KEY_ID     = var.s3_access_key_id
      AWS_SECRET_ACCESS_KEY = var.s3_secret_access_key
      CACHE_TTL             = "300"
      PRESIGN_TTL           = "900"
    }
  }
}

resource "aws_lambda_function_url" "this" {
  function_name      = aws_lambda_function.this.function_name
  authorization_type = "NONE"
}

# CloudFront na frente da Function URL: HTTPS + cache de manifests (TTL curto).
locals {
  origin_domain = replace(replace(aws_lambda_function_url.this.function_url, "https://", ""), "/", "")
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  price_class     = "PriceClass_100"
  comment         = "vod streaming-distribution"
  is_ipv6_enabled = true

  origin {
    domain_name = local.origin_domain
    origin_id   = "distribution-lambda"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "distribution-lambda"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    # Managed policy "CachingDisabled" como default; manifests usam TTL curto via app headers.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
