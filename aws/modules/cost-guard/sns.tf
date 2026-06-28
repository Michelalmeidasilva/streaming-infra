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

# Permite que o AWS Budgets publique em cada tópico. O SNS exige que o statement de
# uma topic policy aponte para UM único recurso (o próprio tópico) — por isso um
# documento escopado por tópico, e não um único compartilhado entre os dois.
data "aws_iam_policy_document" "budgets_publish_alerts" {
  statement {
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "budgets_publish_killswitch" {
  statement {
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.killswitch.arn]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.budgets_publish_alerts.json
}

resource "aws_sns_topic_policy" "killswitch" {
  arn    = aws_sns_topic.killswitch.arn
  policy = data.aws_iam_policy_document.budgets_publish_killswitch.json
}
