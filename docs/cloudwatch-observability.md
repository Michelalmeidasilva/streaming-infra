# CloudWatch Observability — Dev (moto) + Prod (AWS CloudWatch)

> **Versão:** 2026-06-06
> **Planos de referência:** `docs/design-docs/plans/2026-06-06-infra-cloudwatch-observability.md` (Plan 2) e `docs/design-docs/specs/2026-06-06-cloudwatch-observability-migration-design.md`

---

## Overview

A plataforma VOD usa **Embedded Metric Format (EMF)** como canal de observabilidade: cada serviço emite métricas como JSON estruturado no stdout (sem código de envio — só um `log.Info`/`fmt.Println` com o envelope EMF). Em prod, o CloudWatch extrai essas métricas nativamente a partir dos log groups. Em dev, um sidecar `emf-forwarder` faz essa extração e envia ao emulador `moto`.

**Sinais coletados (6):**

| # | Sinal | Fonte |
|---|---|---|
| 1 | Requests (RequestCount) | EMF dos serviços |
| 2 | CPU (Duration proxy) | Lambda nativa em prod; não disponível em dev |
| 3 | Memory (Max Memory Used) | Linha `REPORT` do Lambda (filtro de log planejado) em prod |
| 4 | Errors (ErrorCount) | EMF dos serviços |
| 5 | Latency (LatencyMs p95) | EMF dos serviços |
| 6 | Traffic (bytes) | CloudFront nativa em prod |

**Sinais 7/8/9 (RabbitMQ / Redis / MongoDB) foram descartados em prod** — esses datastores são gerenciados externamente (CloudAMQP, ElastiCache, DocumentDB) e não há exporters apontando para eles. Em dev, o modelo pull/scrape foi removido junto com o Prometheus.

---

## Dev

### Stack (construído e verificado)

```
services (EMF → stdout)
    └─► emf-forwarder (sidecar Python + boto3 + docker SDK)
              └─► moto (emulador OSS CloudWatch)  porta host 5001 → container 5000
                        └─► Grafana (datasource CloudWatch → http://moto:5000)
                                  └─► dashboard "VOD Golden Signals"
```

Componentes:

| Container | Imagem / origem | Porta host | Notas |
|---|---|---|---|
| `moto` | `motoserver/moto` (Apache-2.0) | **5001** → 5000 | Host 5000 ocupado pelo AirPlay no macOS |
| `emf-forwarder` | `infra/observability/emf-forwarder/` (Python + boto3 + docker SDK) | — | Monta o socket Docker read-only |
| `grafana` | `grafana/grafana` | 3009 | Datasource: `infra/observability/grafana-datasources.cloudwatch.yaml` |

**Como funciona o emf-forwarder:** acompanha o stdout de cada container de serviço via docker socket (read-only), parseia cada linha JSON com envelope EMF, e chama `cloudwatch.put_metric_data` no moto. Emite **duas cópias** de cada métrica: uma com todas as dimensões originais e uma cópia _dimensionless_ (sem dimensões), necessária por conta da limitação de queries do moto (ver abaixo).

### Subir a stack de observabilidade em dev

```bash
cd infra
docker compose up -d moto emf-forwarder grafana \
  streaming-ingest streaming-distribution streaming-transcode
```

- Grafana: http://localhost:3009 (admin / admin)
- moto CloudWatch (para debug direto via AWS CLI):
  ```bash
  aws --endpoint-url=http://localhost:5001 cloudwatch list-metrics --namespace VOD/ingest
  ```

O dashboard "VOD Golden Signals" está em `infra/observability/dashboards/vod-golden-signals.json` e é provisionado automaticamente pelo Grafana.

### Limitações do moto em dev

1. **Sem extração EMF server-side:** nenhum emulador gratuito (moto ou LocalStack community) extrai métricas de logs EMF automaticamente. Por isso existe o `emf-forwarder` — ele faz essa extração no lado do cliente.

2. **Sem CloudWatch Metric Insights SEARCH:** o moto não implementa a função `SEARCH(...)` do Metric Insights. Queries Grafana com wildcard ou dimensões parciais retornam vazio. Por isso o dashboard consulta a cópia _dimensionless_ com `matchExact: true`. **Em prod (CloudWatch real) essa limitação não existe** — nenhuma dessas adaptações seria necessária.

3. **Por que não LocalStack:** a investigação completa está em `infra/observability/SPIKE-localstack-emf.md`. Em resumo: LocalStack community 3.x tem incompatibilidade de protocolo com o aws CLI 2.34 (erro `query-protocol`); LocalStack 4.x (`:latest`) requer licença paga. O moto foi escolhido por ser 100% OSS, Apache-2.0, e funcionar com o aws CLI atual.

---

## Prod

### O que está construído

**Gerenciado e comitado:**

- `aws_cloudwatch_log_group` com retenção de 14 dias para os Lambdas de ingest e distribution, adicionados em `infra/aws/modules/ingest-lambda/` e `infra/aws/modules/distribution-lambda/`. Cada módulo expõe o output `log_group_name`.

**Fluxo de métricas em prod:**

```
Lambda/CloudFront/Batch/EventBridge  →  métricas nativas CloudWatch
serviços (stdout EMF)  →  CloudWatch Logs  →  extração EMF nativa  →  namespace VOD/<service>
```

Em prod o CloudWatch extrai EMF nativamente — não há forwarder, não há moto, não há adaptações de dimensão.

### Caveat: Lambda Insights em container-image

Ambos os Lambdas usam `package_type = "Image"`. A camada do Lambda Insights **não pode ser anexada** a funções container-image. Por isso:

- Signal 2 (CPU) → proxy via métrica nativa `Duration`.
- Signal 3 (Memory) → extração via filtro de log sobre a linha `REPORT` do Lambda (`Max Memory Used`). Instalação completa do Lambda Insights (baking da extensão na imagem) está fora de escopo e documentada como opção futura.

### O que está planejado (não construído)

O módulo Terraform `infra/aws/modules/observability` — que incluiria o dashboard CloudWatch, os alarms (Lambda errors/p95, CloudFront 5xx) e o filtro de log para memória Lambda — está **especificado no plano A2–A4** (`docs/design-docs/plans/2026-06-06-infra-cloudwatch-observability.md`) mas foi **adiado** porque o binário `terraform` não está disponível neste ambiente (impossível validar). Não execute `terraform apply` até que esse módulo seja implementado.

Itens planejados (A2–A4):

- `infra/aws/modules/observability/main.tf` — dashboard CloudWatch + alarms Lambda errors/p95 + alarm CloudFront 5xx + filtro de log `Max Memory Used`.
- `infra/aws/modules/observability/variables.tf` e `outputs.tf`.
- Instanciação de `module "observability"` em `infra/aws/main.tf` (wiring com os módulos Lambda, CloudFront, Batch).

---

## Referências

- Spec de design: `infra/docs/design-docs/specs/2026-06-06-cloudwatch-observability-migration-design.md`
- Plano de implementação: `infra/docs/design-docs/plans/2026-06-06-infra-cloudwatch-observability.md`
- Spike LocalStack vs moto: `infra/observability/SPIKE-localstack-emf.md`
- Datasource Grafana dev: `infra/observability/grafana-datasources.cloudwatch.yaml`
- Dashboard Grafana: `infra/observability/dashboards/vod-golden-signals.json`
- emf-forwarder: `infra/observability/emf-forwarder/`
