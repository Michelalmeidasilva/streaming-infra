locals {
  alarm_actions = var.alarm_sns_topic_arn == "" ? [] : [var.alarm_sns_topic_arn]
}

# Extract "Max Memory Used" from each Lambda REPORT line into a metric (signal 3 in prod,
# since container-image lambdas can't use the Insights layer).
resource "aws_cloudwatch_log_metric_filter" "lambda_max_memory" {
  count          = length(var.lambda_function_names)
  name           = "${var.lambda_function_names[count.index]}-max-memory"
  log_group_name = var.lambda_log_group_names[count.index]
  pattern        = "[report_label=\"REPORT\", ..., max_memory_label=\"Max\", used_label=\"Memory\", used2_label=\"Used:\", max_memory_value, mb_label=\"MB\"]"

  metric_transformation {
    name      = "MaxMemoryUsedMB"
    namespace = "VOD/lambda-${var.lambda_function_names[count.index]}"
    value     = "$max_memory_value"
    unit      = "Megabytes"
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  count               = length(var.lambda_function_names)
  alarm_name          = "${var.lambda_function_names[count.index]}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = var.lambda_function_names[count.index] }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = var.error_rate_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "lambda_p95_latency" {
  count               = length(var.lambda_function_names)
  alarm_name          = "${var.lambda_function_names[count.index]}-p95-duration"
  namespace           = "AWS/Lambda"
  metric_name         = "Duration"
  dimensions          = { FunctionName = var.lambda_function_names[count.index] }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.p95_latency_ms_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "cloudfront_5xx" {
  provider            = aws.us_east_1
  alarm_name          = "cloudfront-5xx-error-rate"
  namespace           = "AWS/CloudFront"
  metric_name         = "5xxErrorRate"
  dimensions          = { DistributionId = var.cloudfront_distribution_id, Region = "Global" }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

resource "aws_cloudwatch_dashboard" "golden_signals" {
  dashboard_name = "VOD-Golden-Signals-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6,
        properties = {
          title  = "Requests (Invocations) + Errors",
          region = var.aws_region,
          metrics = concat(
            [for fn in var.lambda_function_names : ["AWS/Lambda", "Invocations", "FunctionName", fn]],
            [for fn in var.lambda_function_names : ["AWS/Lambda", "Errors", "FunctionName", fn]]
          ),
          stat = "Sum", period = 60
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6,
        properties = {
          title   = "Latency p95 (Duration)",
          region  = var.aws_region,
          metrics = [for fn in var.lambda_function_names : ["AWS/Lambda", "Duration", "FunctionName", fn]],
          stat    = "p95", period = 300
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6,
        properties = {
          title   = "Max Memory Used (MB)",
          region  = var.aws_region,
          metrics = [for fn in var.lambda_function_names : ["VOD/lambda-${fn}", "MaxMemoryUsedMB"]],
          stat    = "Maximum", period = 300
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6,
        properties = {
          title  = "CloudFront traffic + 5xx",
          region = "us-east-1",
          metrics = [
            ["AWS/CloudFront", "BytesDownloaded", "DistributionId", var.cloudfront_distribution_id, "Region", "Global"],
            ["AWS/CloudFront", "5xxErrorRate", "DistributionId", var.cloudfront_distribution_id, "Region", "Global"]
          ],
          stat = "Sum", period = 300
        }
      }
    ]
  })
}
