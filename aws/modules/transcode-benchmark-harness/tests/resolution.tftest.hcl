variables {
  benchmark_session_id = "123e4567-e89b-42d3-a456-426614174000"
  corpus_bucket        = "vod-streaming-upload-dev"
  ingest_benchmark_url = "http://ingest.internal/api/v1"
  vpc_id               = "vpc-0123456789abcdef0"
  subnet_id            = "subnet-0123456789abcdef0"
  ecr_image_cpu        = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  ecr_image_gpu        = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode-gpu:latest"
}

run "cpu_x86_uses_cpu_image" {
  command = plan
  variables {
    benchmark_instance_types = ["c5.xlarge"]
  }
  assert {
    condition     = local.instances["c5.xlarge"].image == var.ecr_image_cpu
    error_message = "Tipo CPU x86 deve usar a imagem CPU."
  }
  assert {
    condition     = local.instances["c5.xlarge"].arch == "x86_64"
    error_message = "c5.xlarge deve ser x86_64."
  }
  assert {
    condition     = local.instances["c5.xlarge"].ami == data.aws_ami.al2023_x86.id
    error_message = "c5.xlarge deve usar o AMI AL2023 x86_64."
  }
}

run "graviton_uses_cpu_image_arm" {
  command = plan
  variables {
    benchmark_instance_types = ["c7g.xlarge"]
  }
  assert {
    condition     = local.instances["c7g.xlarge"].image == var.ecr_image_cpu
    error_message = "Graviton deve usar a imagem CPU (multi-arch)."
  }
  assert {
    condition     = local.instances["c7g.xlarge"].arch == "arm64"
    error_message = "c7g.xlarge deve ser arm64."
  }
  assert {
    condition     = local.instances["c7g.xlarge"].ami == data.aws_ami.al2023_arm.id
    error_message = "c7g.xlarge deve usar o AMI AL2023 arm64."
  }
}

run "gpu_uses_gpu_image" {
  command = plan
  variables {
    benchmark_instance_types = ["g6.xlarge"]
  }
  assert {
    condition     = local.instances["g6.xlarge"].image == var.ecr_image_gpu
    error_message = "Tipo GPU deve usar a imagem GPU."
  }
  assert {
    condition     = local.instances["g6.xlarge"].gpu == true
    error_message = "g6.xlarge deve ser gpu=true."
  }
  assert {
    condition     = local.instances["g6.xlarge"].ami == data.aws_ami.gpu_x86.id
    error_message = "g6.xlarge deve usar o AMI GPU."
  }
}
