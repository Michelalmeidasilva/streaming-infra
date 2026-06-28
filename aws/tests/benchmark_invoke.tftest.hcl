# Testa que aws_iam_user_policy.benchmark_invoke é criada (count=1) quando o benchmark
# está habilitado, está vinculada ao usuário correto (vod-storage-svc) e ausente quando
# enable_transcode_benchmark_harness=false.
#
# CONTEXTO CI: este teste usa `command = plan` contra o root completo, que inclui
# data sources AWS (aws_availability_zones no módulo network; aws_ami no benchmark
# harness). Portanto exige credenciais AWS de leitura válidas + acesso a us-east-2.
# Em CI sem credenciais, use `terraform -chdir=aws validate` como gate.
#
# LIMITAÇÃO DE PLANO — conteúdo da policy:
#   `aws_iam_user_policy.benchmark_invoke[0].policy` é UNKNOWN durante o plan porque
#   o campo Resource referencia `module.benchmark_trigger[0].function_arn` (ARN da Lambda
#   computado apenas após apply). Por isso NÃO é possível fazer regex no JSON da policy
#   neste teste para confirmar "lambda:InvokeFunctionUrl" e ausência de "ec2:".
#   A correção estrutural (Action literal, Condition, Resource) é verificada por
#   `terraform validate` + inspeção de código. A asserção de conteúdo requereria mocks
#   ou um apply real.

variables {
  storage_bucket_name = "fake-bucket-for-test"
  mongodb_uri         = "mongodb+srv://user:pass@cluster.mongodb.net/streaming"
  rabbitmq_url        = "amqps://user:pass@host.cloudamqp.com/vhost"
  redis_url           = "rediss://user:pass@host:6379"

  enable_transcode_benchmark_harness = true
  benchmark_instance_types           = ["c5.2xlarge"]
}

run "benchmark_invoke_policy_created" {
  command = plan

  assert {
    condition     = length(aws_iam_user_policy.benchmark_invoke) == 1
    error_message = "aws_iam_user_policy.benchmark_invoke deve ser criada (count=1) quando enable_transcode_benchmark_harness=true."
  }

  assert {
    condition     = aws_iam_user_policy.benchmark_invoke[0].name == "vod-benchmark-invoke"
    error_message = "O nome da policy deve ser 'vod-benchmark-invoke'."
  }

  assert {
    condition     = aws_iam_user_policy.benchmark_invoke[0].user == var.iam_user_name
    error_message = "A policy deve estar vinculada ao usuário IAM gerenciado pelo módulo iam_s3 (vod-storage-svc por padrão)."
  }
}

run "benchmark_invoke_absent_when_disabled" {
  command = plan

  variables {
    enable_transcode_benchmark_harness = false
    benchmark_instance_types           = []
  }

  assert {
    condition     = length(aws_iam_user_policy.benchmark_invoke) == 0
    error_message = "aws_iam_user_policy.benchmark_invoke NAO deve existir quando enable_transcode_benchmark_harness=false."
  }
}
