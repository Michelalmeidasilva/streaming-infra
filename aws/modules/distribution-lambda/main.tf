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
      # O distribution seleciona o S3Adapter só com "aws-s3" (cmd/api/main.go); com "s3"
      # caía no MinioAdapter → client nil → presign "storage client not initialized" → 500.
      STORAGE_PROVIDER  = "aws-s3"
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
      # Playback no browser exige modo CDN: presigned assina só o master.m3u8, e as
      # playlists/segmentos filhos (URL relativa) dariam 403 no bucket privado. Com CDN_BASE
      # o URLBuilder devolve URLs públicas do CloudFront (mesma distribution, behaviors
      # transcoded/* e thumbnails/* → origem S3 via OAC), e os filhos relativos resolvem.
      CDN_BASE = "https://${aws_cloudfront_distribution.this.domain_name}"
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

# Bucket de mídia (segmentos/manifests transcodados). Usado como 2ª origem do CloudFront.
data "aws_s3_bucket" "storage" {
  bucket = var.storage_bucket_name
}

# OAC (tipo s3): só o CloudFront lê o bucket privado; o viewer recebe URLs públicas.
resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.function_name}-media-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Responde o preflight CORS (OPTIONS) da mídia no edge. Necessária porque o player injeta
# o header custom `x-api-key` em toda request → preflight; e o S3 (OAC) recusa o OPTIONS
# assinado (403). Ver media_cors.js. Fix de raiz seria o web-client não mandar x-api-key
# em recursos do CDN, mas isso resolve no edge sem redeploy do web-client.
resource "aws_cloudfront_function" "media_cors" {
  name    = "${var.function_name}-media-cors"
  runtime = "cloudfront-js-2.0"
  comment = "Answer CORS preflight (OPTIONS) for media behaviors at the edge"
  publish = true
  code    = file("${path.module}/media_cors.js")
}

# viewer-response: injeta ACAO no GET/HEAD da mídia. A SimpleCORS não aplica o ACAO quando
# o player manda o header custom x-api-key; aqui é determinístico. Ver media_cors_response.js.
resource "aws_cloudfront_function" "media_cors_response" {
  name    = "${var.function_name}-media-cors-resp"
  runtime = "cloudfront-js-2.0"
  comment = "Inject access-control-allow-origin on media responses"
  publish = true
  code    = file("${path.module}/media_cors_response.js")
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

  # 2ª origem: bucket S3 de mídia (OAC). Serve transcoded/* e thumbnails/* publicamente.
  origin {
    domain_name              = data.aws_s3_bucket.storage.bucket_regional_domain_name
    origin_id                = "distribution-media-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.media.id
  }

  default_cache_behavior {
    target_origin_id       = "distribution-apigw"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    # Managed policy "CachingDisabled" como default; manifests usam TTL curto via app headers.
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    # Sem origin request policy o CloudFront NÃO repassa os headers de preflight CORS
    # (Access-Control-Request-Method/Headers) para a origem. O middleware CORS do Fiber
    # então não reconhece o OPTIONS como preflight, cai no router (só GET/HEAD) e retorna
    # 405 — quebrando o GET cross-site do web-client. ATENÇÃO: a managed "CORS-CustomOrigin"
    # nesta conta só encaminha `origin` (não os headers de preflight), então NÃO resolve.
    # Usamos "AllViewerExceptHostHeader", que encaminha todos os headers do viewer
    # (Origin, Access-Control-Request-Method/Headers, x-api-key) EXCETO Host — preservando
    # o roteamento do API Gateway — deixando o Fiber responder o preflight com 204.
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader
  }

  # Mídia transcodada → origem S3. CachingOptimized (segmentos imutáveis). O CORS é feito
  # nas CloudFront Functions (preflight no viewer-request, ACAO no viewer-response): a
  # SimpleCORS não aplica o ACAO quando o player manda o header custom x-api-key.
  ordered_cache_behavior {
    path_pattern           = "transcoded/*"
    target_origin_id       = "distribution-media-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.media_cors.arn
    }
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.media_cors_response.arn
    }
  }

  ordered_cache_behavior {
    path_pattern           = "thumbnails/*"
    target_origin_id       = "distribution-media-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.media_cors.arn
    }
    function_association {
      event_type   = "viewer-response"
      function_arn = aws_cloudfront_function.media_cors_response.arn
    }
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

# Bucket policy: só este CloudFront (via OAC) lê o bucket. Não é "público" (principal de
# serviço + SourceArn), então passa pelo Block Public Access do bucket.
data "aws_iam_policy_document" "media_oac_read" {
  statement {
    sid       = "AllowCloudFrontOACRead"
    actions   = ["s3:GetObject"]
    resources = ["${data.aws_s3_bucket.storage.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "media_oac" {
  bucket = data.aws_s3_bucket.storage.id
  policy = data.aws_iam_policy_document.media_oac_read.json
}
