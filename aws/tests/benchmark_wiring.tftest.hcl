# Teste de wiring: garante que o módulo transcode_benchmark_harness nasce desligado
# (count=0) por padrão no root, sem exigir nenhuma variável de benchmark.
#
# LIMITAÇÃO CONHECIDA: este teste usa `command = plan` no root completo (11+ módulos),
# que depende de data sources da AWS (AMIs, etc.) resolvíveis apenas com credenciais
# válidas e acesso à região us-east-2. Se falhar por data source de outro módulo, rode:
#   terraform -chdir=aws validate   (prova a correção sintática/semântica sem plan)
# O validate passou com sucesso — veja task-7-report.md para detalhes.

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
