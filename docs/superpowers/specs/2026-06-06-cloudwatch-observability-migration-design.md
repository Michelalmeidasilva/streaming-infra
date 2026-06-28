# Observability Migration — Prometheus self-hosted → AWS CloudWatch

> **Status:** design aprovado em brainstorming, pendente review do spec escrito.
> **Data:** 2026-06-06
> **Repos afetados:** `infra/`, `streaming-ingest/`, `streaming-distribution/`,
> `streaming-transcode/`, `streaming-platform-upload/`, `streaming-telemetry/` (arquivar),
> `obsidian-vault/`.

## Motivação

A stack de observabilidade atual (Prometheus + Grafana + cAdvisor + redis_exporter +
mongodb_exporter + plugin rabbitmq_prometheus, modelo **pull/scrape**) foi desenhada para
containers de longa duração. Mas o alvo de produção é **serverless**:

- `streaming-ingest`, `streaming-distribution` → **AWS Lambda**
- `streaming-transcode` → **AWS Batch**
- eventos → **EventBridge**
- web-client → **CloudFront + S3**

No serverless o modelo pull **não funciona**: Lambda é efêmera e escala a zero — não há
container vivo para o cAdvisor inspecionar nem endpoint `/metrics` estável para o Prometheus
raspar. Além disso, sobrou *dead weight*: os 4 serviços ainda inicializam um pipeline OTel
SDK *push* apontando para `localhost:4317` (o otelcol que foi removido na migração anterior),
gastando CPU (retry de gRPC, batching, auto-instrumentation no Node) sem entregar nada.

**Objetivo:** trocar todo o módulo de observabilidade por **AWS CloudWatch**, aproveitando as
métricas nativas do Lambda/Batch/CloudFront/EventBridge, mantendo as mesmas (ou quase as
mesmas) funcionalidades com muito menos peças móveis e zero código morto.

## Decisões travadas (brainstorming 2026-06-06)

1. **Destino:** AWS CloudWatch (Metrics + Logs). Modelo *push* nativo, não mais pull/scrape.
2. **Sinais 7 (DLQ/lag RabbitMQ), 8 (latência Redis), 9 (latência Mongo): DROPADOS em prod.**
   Os datastores são todos externos gerenciados (CloudAMQP, Redis externo, MongoDB Atlas) e o
   CloudWatch não os enxerga nativamente. Ficam monitorados pelos dashboards próprios de cada
   provedor. Restam **6 sinais**.
3. **Dev local:** LocalStack como CloudWatch "de verdade" — o mesmo código de emissão roda em
   dev (apontando para `localstack:4566`) e em prod (CloudWatch real). Grafana mantido como
   visualizador, com **datasource CloudWatch** (substitui o Prometheus).
4. **Endpoints `/metrics` (fiberprometheus/prom-client da Fase 2): REMOVIDOS.** Sem Prometheus,
   ninguém raspa. RED passa a ser emitido via **EMF** (Embedded Metric Format).
5. **OTel SDK: REMOVIDO** dos 4 serviços (`internal/otel/`, `instrumentation.ts`).
6. **`streaming-telemetry/`: absorvido em `infra/` e arquivado.** A observabilidade inteira
   passa a viver em `infra/` (Terraform em prod + docker-compose/LocalStack em dev).
7. **Tracing (X-Ray): fora de escopo.** Mantém a filosofia metrics-only da migração anterior.

## Arquitetura alvo

```
PROD (AWS)                               DEV (local, docker-compose)
─────────────                           ───────────────────────────
Lambda / Batch / CloudFront /            LocalStack  (SERVICES=cloudwatch,logs :4566)
EventBridge                                  ▲
   │ métricas nativas (grátis)               │ EMF / PutMetricData  (mesmo código,
   │ + EMF dos serviços                      │   só muda AWS_ENDPOINT_URL)
   ▼                                      serviços (containers no compose)
CloudWatch (Metrics + Logs)                  │
   ├── Dashboard "VOD Golden Signals"     Grafana (datasource CloudWatch → localstack:4566)
   └── Alarms (erros, p95, 5xx CDN)
```

**Invariante de design:** o código de emissão de telemetria é idêntico nos dois ambientes;
só o endpoint muda. Em prod, as métricas nativas do Lambda/Batch/CloudFront vêm por cima,
de graça, sem instrumentação.

## Contrato de sinais (6 sinais)

| # | Sinal | Prod (fonte) | Dev (fonte) |
|---|-------|--------------|-------------|
| 1 | Requests | Lambda `Invocations` · CloudFront `Requests` | EMF `RequestCount` |
| 2 | CPU | Lambda Insights `cpu_total_time` | n/d local (aceito) |
| 3 | Memória | Lambda `max-memory-used` · Insights | n/d local (aceito) |
| 4 | Erros | Lambda `Errors` · CloudFront `5xxErrorRate` | EMF `ErrorCount` |
| 5 | Latência | Lambda `Duration` · CloudFront `OriginLatency` | EMF `RequestLatency` |
| 6 | Tráfego | CloudFront `BytesDownloaded` | n/d local (aceito) |
| ~~7~~ | ~~DLQ/lag~~ | **dropado** | — |
| ~~8~~ | ~~Redis~~ | **dropado** | — |
| ~~9~~ | ~~Mongo~~ | **dropado** | — |

Os RED (1/4/5) são cobertos pelo EMF do serviço **em ambos** os ambientes; as métricas
nativas do Lambda/CloudFront em prod são reforço/redundância barata.

## EMF — formato de emissão

Cada serviço escreve no stdout (que vai para CloudWatch Logs, que extrai métricas
automaticamente) um objeto EMF por request:

```json
{
  "_aws": {
    "Timestamp": 1717689600000,
    "CloudWatchMetrics": [{
      "Namespace": "VOD/streaming-ingest",
      "Dimensions": [["service", "route", "method"]],
      "Metrics": [
        {"Name": "RequestCount",   "Unit": "Count"},
        {"Name": "RequestLatency", "Unit": "Milliseconds"},
        {"Name": "ErrorCount",     "Unit": "Count"}
      ]
    }]
  },
  "service": "streaming-ingest",
  "route": "/api/v1/events",
  "method": "POST",
  "RequestCount": 1,
  "RequestLatency": 42.5,
  "ErrorCount": 0
}
```

- **Go (ingest, distribution):** middleware Fiber fino que monta o JSON e faz log no stdout.
  Sem dependência externa (ou `aws-embedded-metrics-go` se preferir tipado).
- **Next (upload):** middleware/wrapper que emite o mesmo shape (`aws-embedded-metrics`
  ou JSON cru via `console.log`).
- **transcode (Batch):** emite EMF de duração/sucesso do job no fim do processamento.

## Mudanças por repositório

### `infra/` (prod — Terraform em `aws/`)
- **Novo `modules/observability/`:**
  - `aws_cloudwatch_dashboard` "VOD Golden Signals" (6 painéis).
  - `aws_cloudwatch_metric_alarm`: erros Lambda, p95 `Duration`, CloudFront `5xxErrorRate`.
- **Lambda Insights** nos 2 Lambdas (layer + `CloudWatchLambdaInsightsExecutionRolePolicy`)
  → sinais 2/3/6.
- Padronizar `aws_cloudwatch_log_group` + `retention_in_days` nos Lambdas (Batch já tem 7d).

### `infra/` (dev — `docker-compose.yml`)
- **Remover:** `prometheus`, `cadvisor`, `redis-exporter`, `mongodb-exporter`, mount/porta do
  plugin `rabbitmq_prometheus`, volumes `prometheus-data`.
- **Adicionar:** serviço `localstack` (`SERVICES=cloudwatch,logs`, `:4566`).
- Serviços ganham `AWS_ENDPOINT_URL=http://localstack:4566` + credenciais dummy.
- **Grafana:** trocar datasource Prometheus → **CloudWatch** apontando para o LocalStack.

### Serviços (`streaming-ingest`, `streaming-distribution`, `streaming-transcode`, `streaming-platform-upload`)
- **Remover OTel SDK:** `internal/otel/` (Go) e `instrumentation.ts` (Next) + deps OTel do
  `go.mod`/`package.json` + as chamadas `otel.Init()` / `register()` nos entrypoints.
- **Remover `/metrics`:** `fiberprometheus/v2` (Go) e `prom-client` + rota `/api/metrics`
  (Next), incluindo os testes desses endpoints.
- **Adicionar helper EMF** (middleware) conforme seção EMF.

### `streaming-telemetry/`
- Mover o que sobrar de útil (dashboards-as-code, docs) para `infra/observability/`.
- Esvaziar/arquivar o repositório (README apontando para `infra/`).

### `obsidian-vault/`
- Sincronizar `services/streaming-telemetry/*` com o novo design (fonte da verdade per
  CLAUDE.md): arquitetura CloudWatch, contrato de 6 sinais, nota de arquivamento.

## Riscos e caveats

1. **LocalStack + EMF:** a extração automática EMF→métrica pode exigir LocalStack **Pro**. Se
   o community não extrair, plano B é `PutMetricData` explícito a partir do mesmo middleware
   (sempre funciona no community). **Validar cedo na implementação.**
2. **Sinais 2/3/6 não existem em dev:** não há Lambda nem CloudFront local; aceito (decisão 3).
   Em dev os painéis correspondentes ficam vazios.
3. **Perda de tracing distribuído:** já era inexistente na prática (sem Tempo/coletor); X-Ray
   fica fora de escopo e pode ser adicionado depois sem retrabalho.
4. **Custo CloudWatch:** EMF gera métricas custom (cobradas). Mitigar com poucas dimensões
   (service/route/method) e sem alta cardinalidade.

## Fora de escopo

- X-Ray / tracing distribuído.
- Re-introduzir os sinais 7/8/9 via poller (decisão: dropados).
- Migrar datastores para serviços AWS-nativos (ElastiCache/DocumentDB/Amazon MQ).

## Verificação

- **Dev:** `docker compose up` → gerar tráfego nos serviços →
  `aws --endpoint-url=http://localhost:4566 cloudwatch list-metrics --namespace VOD/streaming-ingest`
  mostra `RequestCount/RequestLatency/ErrorCount`; Grafana renderiza o dashboard.
- **Prod:** `terraform plan/apply` cria dashboard + alarmes; após deploy, invocar os Lambdas
  e confirmar métricas nativas + EMF no console CloudWatch; alarmes em `OK`.

## Checklist de docs (CLAUDE.md) — por repo tocado

Para cada serviço/infra afetado: atualizar `SPEC.md`, prepend em `CHANGELOG.md`, criar
`docs/<feature>.md`, e sincronizar a `obsidian-vault`.
