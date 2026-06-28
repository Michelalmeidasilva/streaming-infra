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
