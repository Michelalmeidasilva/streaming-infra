# Prova: o orquestrador Lambda não carrega chaves AWS estáticas nas variáveis de ambiente.
# Garante que a autenticação ocorre exclusivamente via IAM role (role-based auth),
# satisfazendo o requisito §4 da spec: "no static AWS keys anywhere".
#
# RED reasoning: se alguém adicionasse AWS_ACCESS_KEY_ID ou AWS_SECRET_ACCESS_KEY
# ao bloco environment { variables {} } em lambda.tf, esses asserts falhariam
# imediatamente, impedindo o merge.

variables {
  image_uri                      = "111122223333.dkr.ecr.us-east-2.amazonaws.com/vod-benchmark-orchestrator:latest"
  benchmark_instance_profile_arn = "arn:aws:iam::111122223333:instance-profile/vod-bench-ec2"
  benchmark_role_arn             = "arn:aws:iam::111122223333:role/vod-bench-ec2"
  benchmark_subnet_id            = "subnet-0123456789abcdef0"
  state_bucket                   = "vod-tfstate-prod-use2"
  corpus_bucket                  = "vod-streaming-upload-dev"
  allowed_instance_types         = ["c5.xlarge"]
}

run "no_aws_access_key_in_env" {
  command = plan

  assert {
    condition     = !contains(keys(try(aws_lambda_function.orchestrator.environment[0].variables, {})), "AWS_ACCESS_KEY_ID")
    error_message = "A Lambda não deve ter AWS_ACCESS_KEY_ID nas variáveis de ambiente — use role-based auth."
  }

  assert {
    condition     = !contains(keys(try(aws_lambda_function.orchestrator.environment[0].variables, {})), "AWS_SECRET_ACCESS_KEY")
    error_message = "A Lambda não deve ter AWS_SECRET_ACCESS_KEY nas variáveis de ambiente — use role-based auth."
  }
}
