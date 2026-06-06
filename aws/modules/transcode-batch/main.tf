data "aws_caller_identity" "current" {}

# ---- IAM: execution role (puxa imagem ECR, lê SSM, escreve logs) ----
data "aws_iam_policy_document" "assume_ecs_tasks" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "vod-${var.environment}-transcode-exec"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_iam_policy_document" "ssm_read" {
  statement {
    actions   = ["ssm:GetParameters"]
    resources = var.ssm_parameter_arns
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "execution_ssm" {
  name   = "vod-${var.environment}-transcode-ssm"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.ssm_read.json
}

# ---- IAM: job role (acesso ao bucket S3 dentro do container) ----
resource "aws_iam_role" "job" {
  name               = "vod-${var.environment}-transcode-job"
  assume_role_policy = data.aws_iam_policy_document.assume_ecs_tasks.json
}

data "aws_iam_policy_document" "s3_rw" {
  statement {
    actions = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::${var.storage_bucket_name}",
      "arn:aws:s3:::${var.storage_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "job_s3" {
  name   = "vod-${var.environment}-transcode-s3"
  role   = aws_iam_role.job.id
  policy = data.aws_iam_policy_document.s3_rw.json
}

# ---- Logs ----
resource "aws_cloudwatch_log_group" "this" {
  name              = "/vod/${var.environment}/transcode"
  retention_in_days = 7
}

# ---- Service-linked role do Batch ----
# CreateComputeEnvironment falha numa conta/região nova se o SLR
# AWSServiceRoleForBatch ainda não existe. Crie-o aqui (uma vez por conta).
# Se já existir na conta, defina create_batch_service_linked_role=false.
resource "aws_iam_service_linked_role" "batch" {
  count            = var.create_batch_service_linked_role ? 1 : 0
  aws_service_name = "batch.amazonaws.com"
}

# ---- Batch compute environment (Fargate Spot) ----
resource "aws_batch_compute_environment" "this" {
  compute_environment_name = "vod-${var.environment}-transcode"
  type                     = "MANAGED"

  compute_resources {
    type               = "FARGATE_SPOT"
    max_vcpus          = 16
    subnets            = var.subnet_ids
    security_group_ids = [var.security_group_id]
  }

  depends_on = [aws_iam_service_linked_role.batch]
}

resource "aws_batch_job_queue" "this" {
  name     = "vod-${var.environment}-transcode"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.this.arn
  }
}

resource "aws_batch_job_definition" "this" {
  name                  = "vod-${var.environment}-transcode"
  type                  = "container"
  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode({
    image            = var.image_uri
    command          = ["transcode-local", "Ref::s3_key"]
    executionRoleArn = aws_iam_role.execution.arn
    jobRoleArn       = aws_iam_role.job.arn

    resourceRequirements = [
      { type = "VCPU", value = "2" },
      { type = "MEMORY", value = "4096" },
    ]

    networkConfiguration = { assignPublicIp = "ENABLED" }

    fargatePlatformConfiguration = { platformVersion = "LATEST" }

    environment = [
      { name = "STORAGE_BUCKET", value = var.storage_bucket_name },
      { name = "STORAGE_PROVIDER", value = "s3" },
      { name = "AWS_REGION", value = var.aws_region },
    ]

    secrets = [
      { name = "MONGODB_URI", valueFrom = "${var.ssm_parameter_prefix}/MONGODB_URI" },
      { name = "S3_ACCESS_KEY_ID", valueFrom = "${var.ssm_parameter_prefix}/S3_ACCESS_KEY_ID" },
      { name = "S3_SECRET_ACCESS_KEY", valueFrom = "${var.ssm_parameter_prefix}/S3_SECRET_ACCESS_KEY" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "transcode"
      }
    }
  })

  parameters = {
    s3_key = "raw/placeholder/original.mp4"
  }
}
