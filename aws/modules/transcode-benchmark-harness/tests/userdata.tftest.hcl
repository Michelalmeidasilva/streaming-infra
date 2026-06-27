variables {
  benchmark_session_id     = "123e4567-e89b-42d3-a456-426614174000"
  benchmark_instance_types = ["c5.xlarge", "g6.xlarge"]
  corpus_bucket            = "vod-streaming-upload-dev"
  ingest_benchmark_url     = "http://ingest.internal/api/v1"
  vpc_id                   = "vpc-0123456789abcdef0"
  subnet_id                = "subnet-0123456789abcdef0"
  ecr_image_cpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  ecr_image_gpu            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode-gpu:latest"
  codecs                   = ["h264", "av1"]
}

run "userdata_sets_session_env" {
  command = plan
  assert {
    condition     = can(regex("BENCHMARK_SESSION_ID=\"123e4567-e89b-42d3-a456-426614174000\"", local.user_data["c5.xlarge"]))
    error_message = "user-data deve exportar BENCHMARK_SESSION_ID."
  }
  assert {
    condition     = can(regex("INGEST_BENCHMARK_URL=\"http://ingest.internal/api/v1\"", local.user_data["c5.xlarge"]))
    error_message = "user-data deve exportar INGEST_BENCHMARK_URL."
  }
}

run "userdata_self_terminates" {
  command = plan
  assert {
    condition     = can(regex("shutdown -h now", local.user_data["c5.xlarge"]))
    error_message = "user-data deve terminar com shutdown (self-terminate)."
  }
}

run "userdata_cpu_uses_plain_docker_run" {
  command = plan
  assert {
    condition     = !can(regex("--gpus all", local.user_data["c5.xlarge"]))
    error_message = "CPU não deve usar --gpus all."
  }
}

run "userdata_gpu_uses_gpus_flag" {
  command = plan
  assert {
    condition     = can(regex("--gpus all", local.user_data["g6.xlarge"]))
    error_message = "GPU deve usar --gpus all."
  }
}
