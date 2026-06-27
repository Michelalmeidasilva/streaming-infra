data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "orchestrator" {
  name_prefix        = "${var.name_prefix}-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "orchestrator" {
  # RunInstances SÓ para os tipos da allowlist
  statement {
    sid       = "RunInstancesAllowlistedTypes"
    actions   = ["ec2:RunInstances"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceType"
      values   = var.allowed_instance_types
    }
  }
  # RunInstances nos demais recursos (AMI, subnet, SG, profile) sem restrição de tipo
  statement {
    sid     = "RunInstancesSupportingResources"
    actions = ["ec2:RunInstances"]
    resources = [
      "arn:aws:ec2:${data.aws_region.current.name}::image/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:subnet/${var.benchmark_subnet_id}",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:security-group/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:network-interface/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:volume/*",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:key-pair/*",
    ]
  }
  # Criar tags só no lançamento
  statement {
    sid       = "TagOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }
  # PassRole SÓ do instance profile do benchmark (converte instance-profile/ → role/)
  statement {
    sid       = "PassBenchmarkRole"
    actions   = ["iam:PassRole"]
    resources = [replace(var.benchmark_instance_profile_arn, ":instance-profile/", ":role/")]
  }
  statement {
    sid       = "PassBenchmarkProfile"
    actions   = ["iam:GetInstanceProfile"]
    resources = [var.benchmark_instance_profile_arn]
  }
  # Describe (necessário ao terraform/EC2) — leitura ampla é aceitável
  statement {
    sid       = "DescribeForTerraform"
    actions   = ["ec2:Describe*"]
    resources = ["*"]
  }
  # Terminate SÓ instâncias com tag Benchmark=true
  statement {
    sid       = "TerminateBenchmarkOnly"
    actions   = ["ec2:TerminateInstances"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Benchmark"
      values   = ["true"]
    }
  }
  # State do terraform no S3
  statement {
    sid       = "TerraformState"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}", "arn:aws:s3:::${var.state_bucket}/*"]
  }
  # Logs
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"]
  }
  # Corpus bucket (leitura para carregar vídeos de referência)
  statement {
    sid       = "CorpusRead"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.corpus_bucket}", "arn:aws:s3:::${var.corpus_bucket}/*"]
  }
}

resource "aws_iam_role_policy" "orchestrator" {
  name   = "${var.name_prefix}-policy"
  role   = aws_iam_role.orchestrator.id
  policy = data.aws_iam_policy_document.orchestrator.json
}
