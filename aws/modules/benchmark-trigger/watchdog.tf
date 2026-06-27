resource "aws_lambda_function" "watchdog" {
  function_name = "${var.name_prefix}-watchdog"
  role          = aws_iam_role.orchestrator.arn
  package_type  = "Image"
  image_uri     = var.image_uri
  image_config {
    command = ["watchdog.watchdogHandler"]
  }
  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      BENCHMARK_TTL_HOURS = tostring(var.ttl_hours)
    }
  }
}

resource "aws_cloudwatch_event_rule" "watchdog" {
  name                = "${var.name_prefix}-watchdog"
  schedule_expression = "rate(15 minutes)"
}

resource "aws_cloudwatch_event_target" "watchdog" {
  rule = aws_cloudwatch_event_rule.watchdog.name
  arn  = aws_lambda_function.watchdog.arn
}

resource "aws_lambda_permission" "watchdog_events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watchdog.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.watchdog.arn
}
