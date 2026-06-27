# NOTA (CI): este teste usa `command = plan` contra o root completo, que inclui
# data sources AWS de outros módulos (ex.: AMI lookups). Portanto exige
# credenciais AWS de leitura válidas + acesso a us-east-2 para rodar. Em CI sem
# credenciais, use `terraform -chdir=aws validate` como gate; este teste é
# credential-gated (rodar no job que tenha AWS_* de leitura).
#
# Teste de wiring: garante que o módulo transcode_benchmark_harness nasce desligado
# (count=0) por padrão no root, sem exigir nenhuma variável de benchmark.

variables {
  # Vars obrigatórias sem default (usadas pelos demais módulos do root).
  storage_bucket_name = "fake-bucket-for-test"
  mongodb_uri         = "mongodb+srv://user:pass@cluster.mongodb.net/streaming"
  rabbitmq_url        = "amqps://user:pass@host.cloudamqp.com/vhost"
  redis_url           = "rediss://user:pass@host:6379"

  # enable_transcode_benchmark_harness usa o default false — não precisa ser
  # explicitado aqui, mas está comentado para documentar a intenção do teste.
  # enable_transcode_benchmark_harness = false
}

run "harness_disabled_by_default" {
  command = plan

  assert {
    condition     = length(module.transcode_benchmark_harness) == 0
    error_message = "O harness deve nascer desligado (count=0) por padrão."
  }
}
