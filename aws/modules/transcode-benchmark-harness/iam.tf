data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "benchmark" {
  name_prefix        = "${var.name_prefix}-ec2-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = { Benchmark = "true" }
}

data "aws_iam_policy_document" "permissions" {
  # Ler o corpus do S3
  statement {
    sid     = "ReadCorpus"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.corpus_bucket}",
      "arn:aws:s3:::${var.corpus_bucket}/${var.corpus_prefix}*",
    ]
  }
  # Puxar imagens do ECR
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPullLayers"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
    ]
    resources = ["arn:aws:ecr:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:repository/vod-transcode*"]
  }
  # Logs
  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:CreateLogGroup",
    ]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/vod/*"]
  }
}

resource "aws_iam_role_policy" "benchmark" {
  name   = "${var.name_prefix}-ec2-policy"
  role   = aws_iam_role.benchmark.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_iam_instance_profile" "benchmark" {
  name_prefix = "${var.name_prefix}-ec2-"
  role        = aws_iam_role.benchmark.name
}
