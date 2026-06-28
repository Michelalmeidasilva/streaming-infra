locals {
  acct   = data.aws_caller_identity.current.account_id
  region = var.target_region

  lambda_arns = [
    for fn in var.lambda_function_names :
    "arn:aws:lambda:${local.region}:${local.acct}:function:${fn}"
  ]
  rule_arns = [
    for r in var.event_rule_names :
    "arn:aws:events:${local.region}:${local.acct}:rule/${r}"
  ]
  batch_queue_arn = "arn:aws:batch:${local.region}:${local.acct}:job-queue/${var.batch_job_queue_name}"
  distribution_arns = [
    for d in var.cloudfront_distribution_ids :
    "arn:aws:cloudfront::${local.acct}:distribution/${d}"
  ]
}

# Empacota a função (zip) a partir do diretório lambda/, excluindo artefatos de teste.
data "archive_file" "killswitch" {
  type        = "zip"
  output_path = "${path.module}/build/killswitch.zip"
  source_dir  = "${path.module}/lambda"
  excludes    = ["test_killswitch.py", "requirements-dev.txt", ".venv"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "killswitch" {
  name               = "vod-${var.environment}-cost-killswitch"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.killswitch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "killswitch" {
  statement {
    sid       = "ZeroLambdaConcurrency"
    actions   = ["lambda:PutFunctionConcurrency"]
    resources = local.lambda_arns
  }
  statement {
    sid       = "DisableEventRules"
    actions   = ["events:DisableRule"]
    resources = local.rule_arns
  }
  statement {
    sid       = "DisableBatchQueue"
    actions   = ["batch:UpdateJobQueue"]
    resources = [local.batch_queue_arn]
  }
  statement {
    sid       = "TerminateBatchJobs"
    actions   = ["batch:ListJobs", "batch:TerminateJob"]
    resources = ["*"] # Batch não suporta resource-level nessas ações
  }
  statement {
    sid       = "DisableDistributions"
    actions   = ["cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"]
    resources = local.distribution_arns
  }
  statement {
    sid       = "NotifyAlerts"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "killswitch" {
  name   = "cost-killswitch"
  role   = aws_iam_role.killswitch.id
  policy = data.aws_iam_policy_document.killswitch.json
}

resource "aws_lambda_function" "killswitch" {
  function_name    = "vod-${var.environment}-cost-killswitch"
  role             = aws_iam_role.killswitch.arn
  handler          = "killswitch.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.killswitch.output_path
  source_code_hash = data.archive_file.killswitch.output_base64sha256

  environment {
    variables = {
      TARGET_REGION               = var.target_region
      LAMBDA_FUNCTION_NAMES       = join(",", var.lambda_function_names)
      EVENT_RULE_NAMES            = join(",", var.event_rule_names)
      BATCH_JOB_QUEUE             = var.batch_job_queue_name
      CLOUDFRONT_DISTRIBUTION_IDS = join(",", var.cloudfront_distribution_ids)
      ALERTS_TOPIC_ARN            = aws_sns_topic.alerts.arn
    }
  }
}

resource "aws_sns_topic_subscription" "killswitch_lambda" {
  topic_arn = aws_sns_topic.killswitch.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.killswitch.arn
}

resource "aws_lambda_permission" "from_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.killswitch.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.killswitch.arn
}
