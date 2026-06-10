locals {
  count_n       = var.enabled ? 1 : 0
  machine_label = var.machine_label != "" ? var.machine_label : var.instance_type
  # ECR registry host is the first path segment of the image URI, e.g.:
  # 123456789012.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest
  ecr_registry = split("/", var.image_uri)[0]
}

# ---- IAM: EC2 instance role for the benchmark instance ----
# Needs: ECR auth token (docker login), SSM read (S3 creds + RabbitMQ),
# S3 read/write (transcode input/output), CloudWatch logs.

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "benchmark" {
  count              = local.count_n
  name               = "vod-${var.environment}-transcode-benchmark"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = var.tags
}

data "aws_iam_policy_document" "benchmark_permissions" {
  # ECR: obtain docker login token
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  # ECR: pull the worker image
  statement {
    sid = "ECRPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }
  # SSM: read S3 credentials (same params Batch reads)
  statement {
    sid       = "SSMRead"
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = var.ssm_parameter_arns
  }
  statement {
    sid       = "KMSDecrypt"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }
  # S3: transcode reads raw video, writes renditions
  statement {
    sid = "S3ReadWrite"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.bucket}",
      "arn:aws:s3:::${var.bucket}/*",
    ]
  }
  # CloudWatch Logs: container log output
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "benchmark" {
  count  = local.count_n
  name   = "vod-${var.environment}-transcode-benchmark-policy"
  role   = aws_iam_role.benchmark[0].id
  policy = data.aws_iam_policy_document.benchmark_permissions.json
}

resource "aws_iam_instance_profile" "benchmark" {
  count = local.count_n
  name  = "vod-${var.environment}-transcode-benchmark"
  role  = aws_iam_role.benchmark[0].name
  tags  = var.tags
}

# ---- EC2 instance running the worker container via user-data ----

resource "aws_instance" "benchmark" {
  count                  = local.count_n
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.benchmark[0].name

  # user-data: installs Docker, fetches S3 creds from SSM, starts the worker.
  # The transcode worker reads STORAGE_PROVIDER=s3 and uses minio-go with
  # static credentials (NewStaticV4), so AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
  # must be supplied explicitly — the SDK cannot fall back to instance metadata here.
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # Install Docker (Amazon Linux 2023 uses dnf; Ubuntu/Debian fallback)
    if command -v dnf &>/dev/null; then
      dnf install -y docker
    elif command -v yum &>/dev/null; then
      yum install -y docker
    else
      apt-get update && apt-get install -y docker.io
    fi
    systemctl enable --now docker

    # Authenticate to ECR
    aws ecr get-login-password --region ${var.aws_region} \
      | docker login --username AWS --password-stdin ${local.ecr_registry}

    # Read S3 credentials and RabbitMQ URL stored in SSM by the ssm-secrets module
    S3_ACCESS_KEY_ID=$(aws ssm get-parameter \
      --name "${var.ssm_parameter_prefix}/S3_ACCESS_KEY_ID" \
      --with-decryption \
      --query "Parameter.Value" \
      --output text \
      --region ${var.aws_region})

    S3_SECRET_ACCESS_KEY=$(aws ssm get-parameter \
      --name "${var.ssm_parameter_prefix}/S3_SECRET_ACCESS_KEY" \
      --with-decryption \
      --query "Parameter.Value" \
      --output text \
      --region ${var.aws_region})

    RABBITMQ_URL=$(aws ssm get-parameter \
      --name "${var.ssm_parameter_prefix}/RABBITMQ_URL" \
      --with-decryption \
      --query "Parameter.Value" \
      --output text \
      --region ${var.aws_region})

    docker run -d --restart=unless-stopped \
      --log-driver=awslogs \
      --log-opt awslogs-region=${var.aws_region} \
      --log-opt awslogs-group=/vod/${var.environment}/transcode-benchmark \
      --log-opt awslogs-create-group=true \
      -e RABBITMQ_URL="$RABBITMQ_URL" \
      -e STORAGE_BUCKET='${var.bucket}' \
      -e STORAGE_PROVIDER='s3' \
      -e AWS_REGION='${var.aws_region}' \
      -e AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" \
      -e AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
      -e EVENT_GATEWAY_URL='${var.event_gateway_url}' \
      -e TRANSCODE_MACHINE_LABEL='${local.machine_label}' \
      -e TRANSCODE_PREFETCH='1' \
      ${var.image_uri}
  EOT

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  tags = merge(var.tags, {
    Name         = "vod-transcode-benchmark-${var.instance_type}"
    MachineLabel = local.machine_label
    Role         = "transcode-benchmark"
    Environment  = var.environment
  })
}
