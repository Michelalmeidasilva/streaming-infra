data "aws_caller_identity" "current" {}

# Tópico informativo — só e-mail (alertas 50/80/forecast + confirmação do kill-switch).
resource "aws_sns_topic" "alerts" {
  name = "vod-${var.environment}-cost-alerts"
}

# Tópico do kill-switch — invoca a Lambda + e-mail de confirmação.
resource "aws_sns_topic" "killswitch" {
  name = "vod-${var.environment}-cost-killswitch"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "killswitch_email" {
  topic_arn = aws_sns_topic.killswitch.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Permite que o AWS Budgets publique nos dois tópicos.
data "aws_iam_policy_document" "budgets_publish" {
  statement {
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn, aws_sns_topic.killswitch.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.budgets_publish.json
}

resource "aws_sns_topic_policy" "killswitch" {
  arn    = aws_sns_topic.killswitch.arn
  policy = data.aws_iam_policy_document.budgets_publish.json
}
