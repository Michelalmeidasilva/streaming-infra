variables {
  benchmark_session_id     = "123e4567-e89b-42d3-a456-426614174000"
  benchmark_instance_types = ["c5.xlarge", "c7g.xlarge", "g6.xlarge"]
  corpus_bucket            = "vod-streaming-upload-dev"
  ingest_benchmark_url     = "http://ingest.internal/api/v1"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_id                = "subnet-0123456789abcdef0"
  ecr_image_cpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  ecr_image_gpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode-gpu:latest"
}

run "one_instance_per_type" {
  command = plan
  assert {
    condition     = length(aws_instance.benchmark) == 3
    error_message = "Deve haver uma instância por tipo selecionado."
  }
}

run "instances_self_terminate" {
  command = plan
  assert {
    condition = alltrue([
      for i in aws_instance.benchmark : i.instance_initiated_shutdown_behavior == "terminate"
    ])
    error_message = "Toda instância deve ter shutdown_behavior=terminate."
  }
}

run "instances_have_required_tags" {
  command = plan
  assert {
    condition = alltrue([
      for k, i in aws_instance.benchmark :
      i.tags["Benchmark"] == "true" &&
      i.tags["SessionId"] == var.benchmark_session_id &&
      i.tags["MachineLabel"] == k
    ])
    error_message = "Tags Benchmark/SessionId/MachineLabel obrigatórias em toda instância."
  }
}

run "instance_type_matches_key" {
  command = plan
  assert {
    condition = alltrue([
      for k, i in aws_instance.benchmark : i.instance_type == k
    ])
    error_message = "instance_type deve casar com a chave do for_each."
  }
}
