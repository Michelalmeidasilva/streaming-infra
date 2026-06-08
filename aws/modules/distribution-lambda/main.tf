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
      STORAGE_PROVIDER  = "s3"
      STORAGE_BUCKET    = var.storage_bucket_name
      TRANSCODED_PREFIX = "transcoded"
      AWS_LWA_PORT      = "8082"
      MONGODB_URI       = var.mongodb_uri
      REDIS_URL         = var.redis_url
      # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY são RESERVADAS pelo Lambda e
      # injetadas automaticamente pela execution role (com AWS_SESSION_TOKEN). O
      # s3_adapter lê as três do ambiente, então o acesso S3 usa a role abaixo.
      CACHE_TTL   = "300"
      PRESIGN_TTL = "900"
    }
  }
}

# A role da Lambda precisa ler o bucket (presign de manifests/segmentos em transcoded/).
data "aws_iam_policy_document" "s3_read" {
  statement {
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.storage_bucket_name}",
      "arn:aws:s3:::${var.storage_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "s3_read" {
  name   = "${var.function_name}-s3-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.s3_read.json
}

# Esta conta AWS (limitada/nova) bloqueia Function URL pública (auth NONE → 403) e a
# OAC do CloudFront→Lambda não autentica neste ambiente. Padrão usado (igual ao ingest):
# a Lambda é exposta por API Gateway HTTP API (público) e o CloudFront fica na frente
# para cache de manifests no edge. O lambda-web-adapter entende o payload v2.0 do HTTP API.
resource "aws_apigatewayv2_api" "this" {
  name          = "${var.function_name}-http"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "this" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.this.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "this" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}

resource "aws_apigatewayv2_stage" "this" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# CloudFront na frente do API Gateway: HTTPS + cache de manifests (TTL curto).
locals {
  origin_domain = replace(aws_apigatewayv2_api.this.api_endpoint, "https://", "")
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  price_class     = "PriceClass_100"
  comment         = "vod streaming-distribution"
  is_ipv6_enabled = true

  origin {
    domain_name = local.origin_domain
    origin_id   = "distribution-apigw"
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "distribution-apigw"
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
