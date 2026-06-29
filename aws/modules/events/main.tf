# ============ Regra comum: S3 ObjectCreated no prefixo raw/ ============
# (S3 entrega eventos ao EventBridge porque o bucket tem eventbridge=true — Plano 1.)

# ---- 2a) S3 → Batch (SubmitJob) : dispara o transcode ----
data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_batch" {
  name               = "vod-${var.environment}-events-batch"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "submit_job" {
  statement {
    actions   = ["batch:SubmitJob"]
    resources = [var.batch_job_queue_arn, var.batch_job_definition_arn]
  }
}

resource "aws_iam_role_policy" "events_batch" {
  name   = "submit-job"
  role   = aws_iam_role.events_batch.id
  policy = data.aws_iam_policy_document.submit_job.json
}

resource "aws_cloudwatch_event_rule" "s3_to_batch" {
  name        = "vod-${var.environment}-s3-to-batch"
  description = "S3 raw/ ObjectCreated -> SubmitJob (transcode)"
  state       = "ENABLED" # gerenciado pelo TF: evita drift silencioso (regra desligada = sem transcode)
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [var.bucket_name] }
      object = { key = [{ prefix = "raw/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "batch" {
  rule     = aws_cloudwatch_event_rule.s3_to_batch.name
  arn      = var.batch_job_queue_arn
  role_arn = aws_iam_role.events_batch.arn

  batch_target {
    job_definition = var.batch_job_definition_arn
    job_name       = "transcode"
  }

  # Passa a key do objeto como parâmetro Ref::s3_key do job.
  input_transformer {
    input_paths = {
      key = "$.detail.object.key"
    }
    input_template = <<EOF
{
  "Parameters": { "s3_key": <key> }
}
EOF
  }
}

# ---- 2b) S3 → ingest webhook (API Destination, POST HTTP) ----
resource "aws_cloudwatch_event_connection" "ingest" {
  name               = "vod-${var.environment}-ingest"
  authorization_type = "API_KEY"
  auth_parameters {
    api_key {
      key   = "x-eventbridge"
      value = "s3-notification"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "ingest" {
  name                             = "vod-${var.environment}-ingest"
  connection_arn                   = aws_cloudwatch_event_connection.ingest.arn
  invocation_endpoint              = "${var.ingest_function_url}api/v1/webhooks/storage/s3"
  http_method                      = "POST"
  invocation_rate_limit_per_second = 10
}

resource "aws_iam_role" "events_api" {
  name               = "vod-${var.environment}-events-api"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "invoke_api" {
  statement {
    actions   = ["events:InvokeApiDestination"]
    resources = [aws_cloudwatch_event_api_destination.ingest.arn]
  }
}

resource "aws_iam_role_policy" "events_api" {
  name   = "invoke-api"
  role   = aws_iam_role.events_api.id
  policy = data.aws_iam_policy_document.invoke_api.json
}

resource "aws_cloudwatch_event_rule" "s3_to_ingest" {
  name        = "vod-${var.environment}-s3-to-ingest"
  description = "S3 raw/ ObjectCreated -> ingest webhook"
  state       = "ENABLED" # gerenciado pelo TF: evita drift silencioso
  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = { name = [var.bucket_name] }
      object = { key = [{ prefix = "raw/" }] }
    }
  })
}

resource "aws_cloudwatch_event_target" "ingest" {
  rule     = aws_cloudwatch_event_rule.s3_to_ingest.name
  arn      = aws_cloudwatch_event_api_destination.ingest.arn
  role_arn = aws_iam_role.events_api.arn
}
