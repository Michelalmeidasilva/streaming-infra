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

data "aws_iam_policy_document" "ssm_read" {
  statement {
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = var.ssm_parameter_arns
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ssm_read" {
  name   = "${var.function_name}-ssm-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.ssm_read.json
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
  timeout       = 30
  memory_size   = 512
  depends_on    = [aws_cloudwatch_log_group.lambda]

  environment {
    variables = {
      STORAGE_PROVIDER = "s3"
      STORAGE_BUCKET   = var.storage_bucket_name
      AWS_LWA_PORT     = "8080"
      MONGODB_URI      = var.mongodb_uri
      RABBITMQ_URL     = var.rabbitmq_url
    }
  }
}

# Esta conta AWS (limitada/nova) bloqueia Function URL pública (auth NONE) — toda
# chamada anônima recebe 403. O ingest tem chamadores EXTERNOS sem credencial AWS
# (Vercel, EventBridge API Destination), então precisa de endpoint público de
# verdade: API Gateway HTTP API (não sujeito ao bloqueio de Function URL).
# O lambda-web-adapter da imagem entende o payload v2.0 do HTTP API igual à Function URL.
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
