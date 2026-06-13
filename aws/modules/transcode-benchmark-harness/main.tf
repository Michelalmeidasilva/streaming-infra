locals {
  count_n         = var.enabled ? 1 : 0
  ecr_registry    = split("/", var.image_uri)[0]
  ami_id          = var.gpu ? data.aws_ami.gpu.id : data.aws_ami.al2023.id
  gpu_flag        = var.gpu ? "--gpus all" : ""
  encoder_backend = var.encoder_backend
}

# ---- AMI lookup: Amazon Linux 2023 matching the requested architecture ----

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-${var.ami_arch}"]
  }

  filter {
    name   = "architecture"
    values = [var.ami_arch]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---- AMI lookup: NVIDIA Deep Learning AMI (used when gpu=true) ----

data "aws_ami" "gpu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [var.gpu_ami_name_filter]
  }

  filter {
    name   = "architecture"
    values = [var.ami_arch]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# ---- IAM: assume-role policy for EC2 ----

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---- IAM: permissions for the benchmark instance ----

data "aws_iam_policy_document" "benchmark_permissions" {
  # ECR: obtain docker login token
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR: pull the transcode image
  statement {
    sid = "ECRPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }

  # SSM: read S3 credentials stored by the ssm-secrets module
  statement {
    sid       = "SSMRead"
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = var.ssm_parameter_arns
  }

  # KMS: decrypt SecureString parameters
  statement {
    sid       = "KMSDecrypt"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }

  # S3: read corpus clips from the benchmark prefix
  statement {
    sid = "S3CorpusRead"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.corpus_bucket}",
      "arn:aws:s3:::${var.corpus_bucket}/*",
    ]
  }

  # CloudWatch Logs: container log output via awslogs driver
  statement {
    sid = "CloudWatchLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }

  # EC2: self-terminate once benchmark completes
  statement {
    sid       = "SelfTerminate"
    actions   = ["ec2:TerminateInstances"]
    resources = ["*"]
  }
}

# ---- IAM role + policy + instance profile (count-gated) ----

resource "aws_iam_role" "benchmark" {
  count              = local.count_n
  name               = "vod-transcode-benchmark-harness"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "benchmark" {
  count  = local.count_n
  name   = "vod-transcode-benchmark-harness-policy"
  role   = aws_iam_role.benchmark[0].id
  policy = data.aws_iam_policy_document.benchmark_permissions.json
}

# SSM core so operators can shell into a live instance to debug (e.g. GPU/NVENC
# issues): aws ssm send-command / start-session. The Deep Learning and AL2023
# AMIs ship the SSM agent, so attaching this is enough to register the instance.
resource "aws_iam_role_policy_attachment" "benchmark_ssm" {
  count      = local.count_n
  role       = aws_iam_role.benchmark[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "benchmark" {
  count = local.count_n
  name  = "vod-transcode-benchmark-harness"
  role  = aws_iam_role.benchmark[0].name
  tags  = var.tags
}

# ---- EC2 instance — runs the benchmark container then self-terminates ----

resource "aws_instance" "benchmark" {
  count                                = local.count_n
  ami                                  = local.ami_id
  instance_type                        = var.instance_type
  subnet_id                            = var.subnet_id
  vpc_security_group_ids               = [var.security_group_id]
  iam_instance_profile                 = aws_iam_instance_profile.benchmark[0].name
  instance_initiated_shutdown_behavior = "terminate"

  root_block_device {
    # GPU (NVIDIA Deep Learning) AMIs ship a large root snapshot (>=75GB); the
    # AL2023 CPU AMI is small. Size up for GPU, leaving room for the corpus +
    # transcode outputs written to the root volume.
    volume_size = var.gpu ? 100 : 50
    volume_type = "gp3"
  }

  # user-data: installs Docker, logs into ECR, reads S3 creds from SSM,
  # runs the benchmark binary inside the transcode container, then self-terminates.
  # The trap on EXIT ensures termination even if docker run fails.
  user_data = <<-EOT
    #!/bin/bash
    set -uo pipefail
    REGION="${var.aws_region}"
    IID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id || true)
    terminate() { aws ec2 terminate-instances --region "$REGION" --instance-ids "$IID" || shutdown -h now; }
    trap terminate EXIT

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
    aws ecr get-login-password --region "$REGION" \
      | docker login --username AWS --password-stdin "${local.ecr_registry}"

    # Read S3 credentials from SSM (same params used by Batch)
    AWS_KEY=$(aws ssm get-parameter \
      --region "$REGION" \
      --with-decryption \
      --name "${var.ssm_parameter_prefix}/S3_ACCESS_KEY_ID" \
      --query Parameter.Value \
      --output text)

    AWS_SECRET=$(aws ssm get-parameter \
      --region "$REGION" \
      --with-decryption \
      --name "${var.ssm_parameter_prefix}/S3_SECRET_ACCESS_KEY" \
      --query Parameter.Value \
      --output text)

    docker run --rm ${local.gpu_flag} \
      --log-driver=awslogs \
      --log-opt awslogs-region="$REGION" \
      --log-opt awslogs-group=/vod/benchmark/transcode \
      --log-opt awslogs-create-group=true \
      -e STORAGE_PROVIDER=s3 \
      -e AWS_REGION="$REGION" \
      -e STORAGE_BUCKET="${var.corpus_bucket}" \
      -e AWS_ACCESS_KEY_ID="$AWS_KEY" \
      -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET" \
      -e BENCHMARK_CORPUS_BUCKET="${var.corpus_bucket}" \
      -e BENCHMARK_CORPUS_PREFIX="${var.corpus_prefix}" \
      -e BENCHMARK_CODECS="${var.codecs}" \
      -e BENCHMARK_RESOLUTIONS="${var.resolutions}" \
      -e BENCHMARK_REPEATS="${var.repeats}" \
      -e BENCHMARK_MODE="${var.benchmark_mode}" \
      -e BENCHMARK_QUALITY_POINTS="${var.quality_points}" \
      -e INGEST_BENCHMARK_URL="${var.ingest_benchmark_url}" \
      -e BENCHMARK_MACHINE_LABEL="${var.machine_label}" \
      -e TRANSCODE_ENCODER_BACKEND="${local.encoder_backend}" \
      "${var.image_uri}" benchmark
  EOT

  tags = merge(var.tags, {
    Name    = "vod-transcode-benchmark-${var.instance_type}"
    Role    = "transcode-benchmark"
    purpose = "benchmark"
  })
}
