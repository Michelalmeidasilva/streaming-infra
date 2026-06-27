variables {
  benchmark_session_id     = "123e4567-e89b-42d3-a456-426614174000"
  benchmark_instance_types = ["c5.xlarge"]
  corpus_bucket            = "vod-streaming-upload-dev"
  ingest_benchmark_url     = "http://ingest.internal/api/v1"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_id                = "subnet-0123456789abcdef0"
  ecr_image_cpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  ecr_image_gpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode-gpu:latest"
}

run "sg_is_created" {
  command = plan
  assert {
    condition     = aws_security_group.benchmark.vpc_id == var.vpc_id
    error_message = "O SG deve ser criado no VPC especificado."
  }
}

run "sg_has_egress_rule" {
  command = plan
  assert {
    condition     = length(aws_security_group.benchmark.egress) == 1
    error_message = "O SG deve ter exatamente uma regra de egress."
  }
}
