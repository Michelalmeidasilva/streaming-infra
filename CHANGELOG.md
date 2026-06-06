## [Unreleased] 2026-06-06
### Added
- Dev observability via moto (OSS CloudWatch emulator) + emf-forwarder sidecar + Grafana CloudWatch datasource.
- Managed CloudWatch log groups (14d retention) for the ingest/distribution Lambdas.
### Removed
- Prometheus/cadvisor/redis-exporter/mongodb-exporter pull stack from docker-compose.
### Notes
- Prod CloudWatch dashboard/alarms module is specified (plan A2–A4) but deferred until terraform tooling is available.

## [Unreleased] 2026-06-03
### Added
- Camada Ansible: build-push (ECR), deploy (lambda update-function-code), configure-broker (topologia CloudAMQP via management API), web-client (build SvelteKit + s3 sync + invalidação CloudFront) e smoke (health checks). Segredos do broker em Ansible Vault.

### Próximo passo (documentado, não implementado)
- GitHub Actions + OIDC: assumir IAM Role federada (sem chave AWS no repo), rodar `terraform plan` no PR e `apply` no merge; encadear os playbooks Ansible no pipeline.

## [Unreleased] 2026-06-03
### Added
- Serviços de compute na AWS (us-east-2): ingest+distribution como Lambda container (Function URL, distribution atrás de CloudFront PriceClass_100), transcode como AWS Batch Fargate Spot disparado por EventBridge (S3 raw/ -> SubmitJob), web-client em S3+CloudFront com OAC. ECR para as 3 imagens. EventBridge S3->ingest (API Destination) preserva o contrato de webhook.
- Terraform foundation AWS (us-east-2): backend S3 + lock nativo, módulos network/ssm-secrets, adoção do bucket S3 existente via import, IAM least-privilege, secrets no SSM. Script de auditoria read-only para recursos existentes.

## [Unreleased] 2026-06-03
### Changed
- Stack de observabilidade simplificada para metrics-only: removidos `otelcol`, `loki`,
  `tempo` e `telemetry-consumer`; adicionados `cadvisor`, `redis-exporter`,
  `mongodb-exporter`; RabbitMQ com plugin `rabbitmq_prometheus` (porta 15692).

## [Unreleased] 2026-06-02
### Changed
- `docker-compose.yml`: cada serviço buildável agora carrega o `.env` do seu próprio projeto via `env_file`.
  - `streaming-platform-upload` passou a apontar para `../streaming-platform-upload/.env` (antes era `.env.example`).
  - `streaming-distribution` e `streaming-web-client` ganharam `env_file` apontando para seus respectivos `.env`.
  - `streaming-ingest` (streaming-ingest) e `streaming-transcode` já carregavam seus `.env` — mantidos.
  - Os blocos `environment:` inline continuam tendo precedência sobre o `env_file` (overrides de rede Docker: `minio:9000`, `streaming-ingest:8080`, etc.).

### Added
- `docker-compose.yml`: stack de observabilidade do `streaming-telemetry` incorporada à infra central (antes vivia só em `streaming-telemetry/docker-compose.yml`):
  - `otelcol` (OTEL Collector, portas 4317/4318/8888/8889), `prometheus` (:9090), `loki` (:3100), `tempo` (:3200, OTLP em 4319→4317), `grafana` (:3000) e `telemetry-consumer`.
  - Build contexts e volumes reescritos para caminhos relativos ao `infra/` (`../streaming-telemetry/...`).
  - Serviços ligados à rede `default` (nomeada `vod-network`) em vez da rede `external`.
  - `telemetry-consumer` com `depends_on` em `rabbitmq` (`service_healthy`) e `otelcol`.
  - Volumes nomeados `prometheus-data`, `loki-data`, `tempo-data`, `grafana-data`.

### Removed
- `streaming-telemetry/docker-compose.yml` removido — a stack de observabilidade passa a viver exclusivamente nesta infra central.
