variables {
  enabled              = true
  instance_types       = ["c5.xlarge", "c5.2xlarge"]
  instance_type        = "c5.xlarge"
  image_uri            = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-transcode:latest"
  subnet_id            = "subnet-0123456789abcdef0"
  security_group_id    = "sg-0123456789abcdef0"
  aws_region           = "us-east-2"
  corpus_bucket        = "vod-storage-2026"
  corpus_prefix        = "benchmark/corpus/"
  codecs               = "h264"
  resolutions          = "1280x720:3000k"
  repeats              = 1
  ingest_benchmark_url = "https://api.example/api/v1"
  ssm_parameter_prefix = "/vod/test"
  ssm_parameter_arns   = ["arn:aws:ssm:us-east-2:111122223333:parameter/vod/test/*"]
}

run "one_instance_per_type" {
  command = plan
  assert {
    condition     = length(aws_instance.benchmark) == 2
    error_message = "Frota deve lançar 1 instância por tipo."
  }
  assert {
    condition     = aws_instance.benchmark["c5.xlarge"].instance_type == "c5.xlarge" && aws_instance.benchmark["c5.2xlarge"].instance_type == "c5.2xlarge"
    error_message = "Cada instância da frota deve ter o instance_type da sua chave."
  }
}

run "single_instance_compat" {
  command = plan
  variables {
    instance_types = []
    instance_type  = "c5.xlarge"
  }
  assert {
    condition     = length(aws_instance.benchmark) == 1
    error_message = "Sem instance_types, cai no single instance_type."
  }
}

run "fleet_without_single_instance_type" {
  command = plan
  variables {
    instance_type  = ""
    instance_types = ["c7g.xlarge"]
  }
  assert {
    condition     = length(aws_instance.benchmark) == 1
    error_message = "Frota deve funcionar sem instance_type definido."
  }
}

run "rejects_empty_both" {
  command         = plan
  expect_failures = [var.instance_type]
  variables {
    enabled        = true
    instance_type  = ""
    instance_types = []
  }
}

run "instances_carry_session_tags" {
  command = plan
  variables {
    instance_types       = ["c5.xlarge"]
    benchmark_session_id = "123e4567-e89b-42d3-a456-426614174000"
  }
  assert {
    condition     = aws_instance.benchmark["c5.xlarge"].tags["Benchmark"] == "true" && aws_instance.benchmark["c5.xlarge"].tags["SessionId"] == "123e4567-e89b-42d3-a456-426614174000" && aws_instance.benchmark["c5.xlarge"].tags["MachineLabel"] == "c5.xlarge"
    error_message = "Instância deve carregar tags de correlação Benchmark/SessionId/MachineLabel."
  }
}
