## [Unreleased] 2026-06-08 — deploy real: Function URL pública bloqueada → API Gateway
### Changed
- `modules/ingest-lambda`: substituída a Function URL por **API Gateway HTTP API**
  ($default stage, integração AWS_PROXY). A conta AWS (limitada/nova, concurrency=10)
  bloqueia Function URL pública (`auth NONE` → 403), e o ingest tem chamadores externos
  sem credencial AWS (Vercel, EventBridge API Destination). Output `function_url` agora
  é a invoke_url do stage (com `/` final via `trimsuffix`).
- `modules/distribution-lambda`: CloudFront agora aponta para **API Gateway HTTP API**
  (não mais Function URL). Tentativa anterior com CloudFront OAC + Function URL `AWS_IAM`
  retornava 403 (OAC→Lambda não autentica neste ambiente), então removida. Env reservadas
  `AWS_ACCESS_KEY_ID/SECRET` saíram do Lambda (são injetadas pela execution role); adicionada
  policy `s3:GetObject/ListBucket` na role para o presign.
- `streaming-distribution/internal/adapters/s3_adapter.go`: `NewStaticV4` passou a incluir
  `AWS_SESSION_TOKEN` (creds temporárias da role no Lambda; token vazio no Batch/local).
### Fixed
- `modules/cost-guard/sns.tf`: policy de tópico SNS apontava para os DOIS ARNs num único
  documento compartilhado → `InvalidParameter: Policy statement must apply to a single
  resource!`. Separado em um documento escopado por tópico.
### Notes
- Imagens das Lambdas devem ser buildadas com `--provenance=false --sbom=false` (buildkit
  do Docker 29 anexa attestation/OCI index → `media type not supported` no CreateFunction).
- Pendência: atualizar a env do ingest na Vercel para a nova URL do API Gateway.

## [Unreleased] 2026-06-08
### Added
- Cost guard: budgets mensal ($40) + diário ($3) → SNS → Lambda kill-switch que
  faz soft-stop reversível (zera concorrência das Lambdas, desabilita regras
  EventBridge, desabilita Batch queue + termina jobs, desabilita CloudFront).
  Re-arm manual via `aws/scripts/cost-guard-rearm.sh`. Módulo `cost-guard`
  (provider us-east-1, pois Budgets é global). Ver `docs/cost-guard.md`.

## [Unreleased] 2026-06-07 — docs: detailed deploy step-by-step
### Added
- `aws/DEPLOY-PASSO-A-PASSO.md`: granular operator guide (Fase 0→4 + apêndices) to provision the stack from scratch — each step as Comando → Saída esperada → Checkpoint, marking 🟢 read-only vs 🔴 mutating steps. Companion to `aws/RUNBOOK.md` (phase overview) and `docs/architecture.md` (diagram). Covers bootstrap state, tfvars placeholders, bucket/ingest import decisions (Image vs Zip), ECR build/push gate, Ansible broker+web-client, E2E smoke, rollback/destroy and re-deploy.

## [Unreleased] 2026-06-07 — docs: full deploy architecture diagram
### Added
- `docs/architecture.md`: end-to-end Mermaid diagram of the cloud topology (AWS us-east-2 + external managed services) covering the upload → EventBridge → Batch transcode → ingest → distribution → CloudFront flow, plus E2E legend and boundaries. Companion view to `aws/RUNBOOK.md`.
- `aws/terraform.tfvars` (git-ignored): generated from `terraform.tfvars.example` with explicit `<PREENCHER-*>` placeholders for the real bucket name and the three external service URLs (Atlas / CloudAMQP / Redis).

## [Unreleased] 2026-06-07 — dev compose: enable E2E auth on the upload service
### Changed
- `docker-compose.yml`: set `E2E_AUTH_ENABLED=1` and `E2E_ADMIN_EMAIL=admin@local.dev` on `streaming-platform-upload`, matching the client build args (`NEXT_PUBLIC_E2E_*`). The server-side bypass was off, so the dockerized upload UI could not authenticate (Google OAuth is the only other provider). Paired with the `e2e.ts` fix in the upload service (the gate no longer depends on the build-frozen `NODE_ENV`). Dev/local only.

## [Unreleased] 2026-06-07 — transcode Batch job: persist via Event Gateway
### Changed
- `modules/transcode-batch`: the job now persists results through the **Event Gateway** (ingest) instead of MongoDB. Dropped the `MONGODB_URI` secret; added `EVENT_GATEWAY_URL` env (new `event_gateway_url` variable), wired in root `main.tf` to `${module.ingest_lambda.function_url}api/v1`. This keeps `streaming-ingest` as the single writer of the `videos` collection that `streaming-distribution` reads (there is no `manifests` collection).
### Fixed
- `modules/transcode-batch`: S3 credential secrets were injected as `S3_ACCESS_KEY_ID`/`S3_SECRET_ACCESS_KEY`, but the service's `config.FromEnv()` reads `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for the `s3` provider (falling back to MinIO dev defaults otherwise). Renamed the injected **env var** names to match; the SSM parameter names stay `S3_*`. Without this the Batch job would have failed S3 auth.

## [Unreleased] 2026-06-07
### Fixed
- emf-forwarder: stop the busy-loop when a target container is stopped (not removed). `containers.get()` still returns a stopped container, so `logs(follow=True)` yielded an already-closed stream and the `while True` re-tailed with no backoff (only the NotFound/exception paths slept). Now skips non-`running` containers and backs off after a normal stream close, polling at 3s instead of hot-spinning.

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
