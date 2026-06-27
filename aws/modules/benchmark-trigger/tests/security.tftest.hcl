variables {
  image_uri                      = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-benchmark-orchestrator:latest"
  benchmark_instance_profile_arn = "arn:aws:iam::111122223333:instance-profile/vod-bench-ec2"
  benchmark_subnet_id            = "subnet-0123456789abcdef0"
  state_bucket                   = "vod-tfstate-prod-use2"
  corpus_bucket                  = "vod-streaming-upload-dev"
  allowed_instance_types         = ["c5.xlarge", "g6.xlarge"]
}

run "function_url_requires_iam_auth" {
  command = plan
  assert {
    condition     = aws_lambda_function_url.orchestrator.authorization_type == "AWS_IAM"
    error_message = "A Function URL deve exigir auth IAM (nunca NONE)."
  }
}

run "run_instances_restricted_to_allowlist" {
  command = plan
  assert {
    condition     = can(regex("c5.xlarge", data.aws_iam_policy_document.orchestrator.json)) && can(regex("g6.xlarge", data.aws_iam_policy_document.orchestrator.json))
    error_message = "A policy deve listar os tipos permitidos na condição de RunInstances."
  }
  assert {
    condition     = can(regex("ec2:InstanceType", data.aws_iam_policy_document.orchestrator.json))
    error_message = "RunInstances deve ter condição ec2:InstanceType."
  }
}

run "passrole_scoped_to_benchmark_profile" {
  command = plan
  assert {
    condition     = can(regex("instance-profile/vod-bench-ec2", data.aws_iam_policy_document.orchestrator.json))
    error_message = "iam:PassRole deve ser restrito ao instance profile do benchmark."
  }
}

run "terminate_scoped_by_tag" {
  command = plan
  assert {
    condition     = can(regex("ec2:ResourceTag/Benchmark", data.aws_iam_policy_document.orchestrator.json))
    error_message = "TerminateInstances deve ser restrito por tag Benchmark."
  }
}
