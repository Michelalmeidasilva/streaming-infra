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
