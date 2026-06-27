# Variáveis válidas reutilizadas pelos run blocks.
variables {
  benchmark_session_id = "123e4567-e89b-42d3-a456-426614174000"
  corpus_bucket        = "vod-streaming-upload-dev"
  ingest_benchmark_url = "http://ingest.internal/api/v1"
  vpc_id               = "vpc-0123456789abcdef0"
  subnet_id            = "subnet-0123456789abcdef0"
  ecr_image_cpu        = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  ecr_image_gpu        = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode-gpu:latest"
}

run "accepts_supported_types" {
  command = plan
  variables {
    benchmark_instance_types = ["c5.xlarge", "c7g.xlarge", "g6.xlarge"]
  }
  assert {
    condition     = length(local.machine_catalog) == 10
    error_message = "O catálogo deve conter exatamente os 10 tipos suportados."
  }
}

run "rejects_unsupported_type" {
  command         = plan
  expect_failures = [var.benchmark_instance_types]
  variables {
    benchmark_instance_types = ["t2.micro"]
  }
}

run "rejects_empty_list" {
  command         = plan
  expect_failures = [var.benchmark_instance_types]
  variables {
    benchmark_instance_types = []
  }
}

run "rejects_over_concurrency_cap" {
  command         = plan
  expect_failures = [var.benchmark_instance_types]
  variables {
    max_concurrent_instances = 2
    benchmark_instance_types = ["c5.xlarge", "c7i.xlarge", "c7g.xlarge"]
  }
}

run "rejects_bad_session_id" {
  command         = plan
  expect_failures = [var.benchmark_session_id]
  variables {
    benchmark_instance_types = ["c5.xlarge"]
    benchmark_session_id     = "not-a-uuid"
  }
}

run "rejects_bad_mode" {
  command         = plan
  expect_failures = [var.mode]
  variables {
    benchmark_instance_types = ["c5.xlarge"]
    mode                     = "turbo"
  }
}
