# Módulo 17 — Redução de Custos Avançada

> **Meta do módulo:** aplicar técnicas concretas para cortar 30–70% da fatura AWS sem degradar SLA — desde escolha de instâncias até redesenho de fluxos onerosos.

**Pré-requisitos:** módulo 14 (FinOps), todos os módulos de serviço (04–13).

---

## 1. Mentalidade: custo é uma feature

Otimizar custo não é "ser barato". É **tomar decisões arquiteturais conscientes**. Todo dólar economizado em infraestrutura pode ir para produto, equipe ou margem. As três perguntas antes de criar qualquer recurso:

1. **Preciso disso agora?** (YAGNI se aplica à infra.)
2. **Qual é o modelo de cobrança e onde vai escalar?**
3. **Existe um serviço mais barato que resolve 80% do problema?**

---

## 2. Alavancas de redução por categoria

### 2.1 Compute (EC2 / ECS / Lambda)

#### Graviton (ARM) — 20–40% mais barato

Toda nova instância deve ser Graviton se o workload suportar:

| On-Demand x86 | On-Demand Graviton | Economia |
|---------------|--------------------|---------|
| `m6i.large` US$ 0.096/h | `m7g.large` US$ 0.0816/h | 15% |
| `r6i.large` US$ 0.126/h | `r7g.large` US$ 0.1008/h | 20% |
| `c6i.large` US$ 0.085/h | `c7g.large` US$ 0.0725/h | 15% |
| ECS Fargate x86 US$ 0.04048/vCPU/h | ECS Fargate ARM US$ 0.03238/vCPU/h | 20% |

**Node.js, Python, Go, Rust** — rodam nativamente em ARM sem alteração de código.

Mudar no Terraform:
```hcl
# Antes
instance_type = "m6i.large"
# Depois
instance_type = "m7g.large"

# ECS task definition
cpu_architecture = "ARM64"  # no runtime_platform
```

#### Savings Plans — 40–66% desconto com compromisso

Comprar **após** 3 meses de histórico de uso. Regra prática:

```
baseline_spend = avg dos últimos 3 meses de EC2+Fargate (excluindo Spot)
comprar Compute SP cobrindo 70% do baseline_spend
deixar 30% On-Demand para variação
```

Calculadora no console: **Cost Explorer → Savings Plans → Recommendations**.

#### Spot para workloads tolerantes a interrupção

| Workload | Spot? | Por quê |
|---------|-------|---------|
| Encoding de vídeo | ✅ Ideal | Batch, reroda de SQS se interrompido |
| Workers batch | ✅ | Idem |
| Testes de carga / CI runners | ✅ | Sem estado |
| Dev/staging | ✅ | Impacto tolerado |
| NestJS prod | ⚠️ Parcial | Só com On-Demand base + Spot suplementar |
| RDS | ❌ | Não suportado |

**Estratégia Mixed Fleet (ASG):**
```hcl
mixed_instances_policy {
  instances_distribution {
    on_demand_base_capacity                  = 1   # 1 OD garantida
    on_demand_percentage_above_base_capacity = 20  # 20% OD, 80% Spot acima da base
    spot_allocation_strategy                 = "price-capacity-optimized"
  }
  override = [
    { instance_type = "m7g.large" },
    { instance_type = "m7g.xlarge" },
    { instance_type = "m6g.large" },  # fallback
  ]
}
```

#### Lambda: ajuste de memória = ajuste de custo

Custo Lambda = `duration_ms × memory_gb × price`. Mais memória = mais CPU = menos tempo. Ponto ótimo nem sempre é o mínimo de memória.

```bash
# aws-lambda-power-tuning (Step Functions)
aws stepfunctions start-execution \
  --state-machine-arn arn:aws:states:...:stateMachine:powerTuningStateMachine \
  --input '{
    "lambdaARN": "arn:aws:lambda:...:function:catalog-update",
    "powerValues": [128,256,512,1024,2048],
    "num": 20,
    "payload": {},
    "parallelInvocation": true,
    "strategy": "cost"
  }'
```

> Resultado comum: função a 512 MB roda em 120ms (US$ 0.00000100/invoc); mesma a 128 MB roda em 600ms (US$ 0.00000100/invoc). Custo idêntico, mas com 512 MB a latência é 5× melhor.

#### ECS: right-size de CPU/RAM

Ferramenta: **AWS Compute Optimizer** (habilitar uma vez, analisa 14 dias).

```bash
aws compute-optimizer get-ecs-service-recommendations \
  --service-arns arn:aws:ecs:us-east-1:123:service/streaming-prod/nestjs-app
```

Mostrará: utilização real de CPU/RAM vs alocado → reduza para o valor recomendado + 20% buffer.

---

### 2.2 Storage (S3 / EBS / ElastiCache)

#### S3 Intelligent-Tiering para padrão desconhecido

```hcl
resource "aws_s3_bucket_intelligent_tiering_configuration" "originals" {
  bucket = aws_s3_bucket.encoded.id
  name   = "whole-bucket"
  tiering {
    access_tier = "DEEP_ARCHIVE_ACCESS"
    days        = 180
  }
  tiering {
    access_tier = "ARCHIVE_ACCESS"
    days        = 90
  }
}
```

Custo de monitoramento: US$ 0.0025/1000 objetos/mês. Vale para buckets com muitos objetos e acesso irregular.

#### S3 Lifecycle agressivo para vídeos originais

```hcl
# Lifecycle no bucket de uploads (originals)
lifecycle_rule {
  id      = "originals-to-glacier"
  enabled = true
  filter { prefix = "uploads/" }
  transition {
    days          = 7
    storage_class = "GLACIER_IR"  # Glacier Instant: acesso em ms se precisar reprocessar
  }
  transition {
    days          = 90
    storage_class = "DEEP_ARCHIVE"
  }
  expiration { days = 1825 }  # 5 anos
  abort_incomplete_multipart_upload { days_after_initiation = 3 }
}
```

Economia típica: original de 1 TB em Standard (US$ 23/mês) → Glacier Deep Archive (US$ 1/mês) = **96% de redução**.

#### EBS: gp3 > gp2

```bash
# Migra volume gp2 para gp3 (sem downtime, sem custo extra)
aws ec2 modify-volume --volume-id vol-xxxx \
  --volume-type gp3 \
  --iops 3000 \
  --throughput 125
```

`gp3` = US$ 0.08/GB/mês. `gp2` = US$ 0.10/GB/mês. **20% mais barato** com mesma performance baseline.

#### ElastiCache: nó certo para o tamanho real

```bash
# Ver utilização real
aws cloudwatch get-metric-statistics \
  --namespace AWS/ElastiCache \
  --metric-name DatabaseMemoryUsagePercentage \
  --dimensions Name=CacheClusterId,Value=streaming-redis-001 \
  --period 3600 --statistics Average \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)
```

Se utilização < 30% do nó, downsize:
```
cache.r7g.large (13GB, US$ 175/mês) → cache.r7g.medium (6.5GB, US$ 87/mês) = 50% menos
```

---

### 2.3 Rede e Transferência de Dados

#### Regra de ouro: dados dentro da AZ são grátis (quase)

| Tráfego | Custo |
|---------|-------|
| Mesmo serviço, mesma AZ | US$ 0 |
| Cross-AZ (dentro da região) | US$ 0.01/GB cada sentido |
| Cross-Region | US$ 0.02/GB |
| Para a internet (EC2/RDS) | US$ 0.09/GB |
| Via CloudFront | US$ 0.085/GB (primeiros 10TB) |
| S3 → CloudFront (mesma região) | US$ 0 |
| S3 → internet direta | US$ 0.09/GB |

**Ação imediata:** configurar `preferred_az` no app para que Fargate tasks e Redis fiquem na mesma AZ sempre que possível.

```hcl
# Pinnar ElastiCache em uma AZ e tasks ECS na mesma
resource "aws_elasticache_replication_group" "redis" {
  preferred_cache_cluster_azs = ["us-east-1a", "us-east-1b"]
  # ...
}
```

#### NAT Gateway: substituir onde possível

**Custo NAT GW:** US$ 0.045/GB processado + US$ 0.045/h fixo.

Substituições:
1. **VPC Gateway Endpoints (S3 + DynamoDB)** — grátis. Tráfego não passa pelo NAT.
2. **VPC Interface Endpoints (outros serviços)** — US$ 0.01/GB, mas só vale se tráfego > 3 GB/mês vs NAT.
3. **NAT Instance** em vez de NAT GW para dev:
   ```hcl
   # t4g.nano com fck-nat AMI: ~US$ 3/mês em vez de US$ 32/mês
   data "aws_ami" "fck_nat" {
     owners      = ["568608671756"]
     most_recent = true
     filter { name = "name"; values = ["fck-nat-al2023-*-arm64-*"] }
   }
   ```
4. Em dev: subnets públicas para workers com SG restritivo (elimina NAT completamente).

**Potencial de economia:** US$ 32 → US$ 3 = **90% de redução** em dev.

#### CloudFront: aumentar cache hit rate

Cache hit rate abaixo de 90% em vídeo é perda de dinheiro (a origem paga duas vezes: pelo request S3 e pela transferência).

Checklist para aumentar hit rate:
- [ ] Segmentos HLS com `Cache-Control: max-age=31536000, immutable`.
- [ ] Manifesto com `Cache-Control: max-age=10, s-maxage=60`.
- [ ] Nenhum query string desnecessário passando para a origem.
- [ ] `Compress=true` no behavior (reduz bytes transferidos).
- [ ] `Origin Shield` habilitado (segunda camada de cache regional).

```bash
# Ver cache hit rate atual
aws cloudwatch get-metric-statistics \
  --namespace AWS/CloudFront \
  --metric-name CacheHitRate \
  --dimensions Name=DistributionId,Value=$CF_ID Name=Region,Value=Global \
  --period 86400 --statistics Average \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ)
```

**CloudFront Price Class:** se usuários são apenas América do Sul + América do Norte:

```hcl
price_class = "PriceClass_100"  # US, Canada, Europe
# vs
price_class = "PriceClass_All"  # global (mais caro)
```

Economia: até 30% em egress.

#### Transferência S3 → Lambda/ECS na mesma região

Configurar **VPC Gateway Endpoint para S3** (já visto no módulo 02) elimina tráfego pelo NAT ou internet. Custo: US$ 0 em vez de US$ 0.045/GB via NAT.

---

### 2.4 Banco de Dados

#### Aurora Serverless v2 para dev/staging

```
RDS r7g.large (prod) = US$ 190/mês (24/7)
Aurora Serverless v2 (staging, ~4h/dia de uso) = 4h × 30d × 0.5 ACU × US$ 0.12 = US$ 7.20/mês
```

**93% de redução em staging** simplesmente por usar Serverless v2.

#### RDS Proxy: reduz tamanho de instância

Com Lambda ou Fargate sem connection pooling, cada instância nova = nova conexão RDS. Resultado: você superaloca a instância do banco para suportar conexões ociosas.

Com RDS Proxy: instância menor suporta mais tasks concorrentes.
```
db.r7g.xlarge (4 vCPU, 32 GB RAM) → db.r7g.large (2 vCPU, 16 GB RAM) com proxy
Economia: US$ 380 → US$ 190/mês = 50%
```

#### DynamoDB: Provisioned + Auto Scaling vs On-Demand

Para workloads com padrão previsível:

```hcl
billing_mode = "PROVISIONED"
read_capacity  = 100
write_capacity = 50

autoscaling_read {
  scale_in_cooldown  = 60
  scale_out_cooldown = 60
  target_value       = 70
  min_capacity       = 10
  max_capacity       = 500
}
```

On-Demand = US$ 1.25/M WCU. Provisioned = US$ 0.00065/WCU/h = US$ 0.47/M WCU efetivo em utilização constante. **~60% mais barato** para carga estável.

---

### 2.5 Observabilidade

#### CloudWatch Logs: comprimir e filtrar antes de ingerir

```ts
// Não logar em INFO dados grandes (body de requests)
// Use sampling: log 1% dos requests bem-sucedidos, 100% dos erros
if (response.statusCode >= 400 || Math.random() < 0.01) {
  logger.log('request', { method, path, statusCode, durationMs });
}
```

Regra: **1 GB de logs a menos = US$ 0.03 economizado**. Parece pouco, mas 100 GB/dia = US$ 90/mês só de ingestão.

#### Métricas: usar EMF em vez de PutMetricData

**Embedded Metrics Format (EMF)** = métricas embutidas nos logs. Sem custo de API `PutMetricData` (US$ 0.30/métrica/mês). CloudWatch extrai automaticamente.

```ts
import { createMetricsLogger, Unit } from 'aws-embedded-metrics';

const metrics = createMetricsLogger();
metrics.setNamespace('Streaming/App');
metrics.putMetric('RequestDuration', durationMs, Unit.Milliseconds);
metrics.putDimensions({ Service: 'nestjs-app' });
await metrics.flush();
```

Economia: 10 métricas custom × US$ 0.30 = US$ 3/mês → US$ 0 com EMF.

#### X-Ray sampling agressivo

```json
{
  "version": 2,
  "rules": [
    {
      "description": "Health checks - ignore",
      "host": "*",
      "http_method": "GET",
      "url_path": "/health",
      "fixed_target": 0,
      "rate": 0
    },
    {
      "description": "Errors - always sample",
      "host": "*",
      "http_method": "*",
      "url_path": "*",
      "fixed_target": 1,
      "rate": 1.0,
      "attributes": { "statusCode": "5*" }
    },
    {
      "description": "Default - 5% sampling",
      "host": "*",
      "http_method": "*",
      "url_path": "*",
      "fixed_target": 1,
      "rate": 0.05
    }
  ]
}
```

Custo X-Ray: US$ 5/M traces. Com 5% sampling em 1M reqs = US$ 0.25/mês em vez de US$ 5.

---

### 2.6 Lambda e API Gateway

#### Lambda: ARM64 (Graviton) = 20% mais barato

```hcl
resource "aws_lambda_function" "catalog_update" {
  architectures = ["arm64"]  # era x86_64
  # Sem mudança no código Node.js/Python
}
```

#### HTTP API vs REST API

```
REST API: US$ 3.50/M requests
HTTP API: US$ 1.00/M requests (3.5× mais barato)
```

Só use REST API se precisar de: caching, request validation com schema, usage plans/API keys, ou WAF na camada do API GW (prefira WAF no CloudFront).

#### Lambda URLs vs API Gateway

Para funções públicas simples (webhooks, callbacks Stripe):

```hcl
resource "aws_lambda_function_url" "webhook" {
  function_name      = aws_lambda_function.stripe_webhook.function_name
  authorization_type = "NONE"
  cors { allow_origins = ["https://hooks.stripe.com"] }
}
```

Custo: US$ 0. API Gateway HTTP API: US$ 1/M. **100% de economia** no API GW.

---

### 2.7 Eliminar recursos ociosos

Script de auditoria semanal:

```bash
#!/bin/bash
# audit-waste.sh

echo "=== Elastic IPs sem associação ==="
aws ec2 describe-addresses \
  --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' \
  --output table

echo "=== EBS volumes disponíveis (não attached) ==="
aws ec2 describe-volumes \
  --filters Name=status,Values=available \
  --query 'Volumes[*].[VolumeId,Size,CreateTime]' \
  --output table

echo "=== Snapshots RDS com mais de 30 dias ==="
aws rds describe-db-snapshots \
  --snapshot-type manual \
  --query 'DBSnapshots[?SnapshotCreateTime<=`'$(date -u -d '30 days ago' +%Y-%m-%d)'`].[DBSnapshotIdentifier,SnapshotCreateTime,AllocatedStorage]' \
  --output table

echo "=== NAT Gateways disponíveis ==="
aws ec2 describe-nat-gateways \
  --filter Name=state,Values=available \
  --query 'NatGateways[*].[NatGatewayId,SubnetId,CreateTime]' \
  --output table

echo "=== Log Groups sem retenção definida ==="
aws logs describe-log-groups \
  --query 'logGroups[?!retentionInDays].[logGroupName,storedBytes]' \
  --output table

echo "=== Load Balancers sem targets saudáveis ==="
for lb in $(aws elbv2 describe-load-balancers --query 'LoadBalancers[*].LoadBalancerArn' --output text); do
  tgs=$(aws elbv2 describe-target-groups --load-balancer-arn $lb --query 'TargetGroups[*].TargetGroupArn' --output text)
  for tg in $tgs; do
    healthy=$(aws elbv2 describe-target-health --target-group-arn $tg \
      --query 'TargetHealthDescriptions[?TargetHealth.State==`healthy`]' --output text)
    if [ -z "$healthy" ]; then
      echo "LB sem targets saudáveis: $lb / $tg"
    fi
  done
done
```

> Agende no EventBridge Scheduler + Lambda toda segunda-feira às 9h. Resultado enviado por e-mail via SES.

---

## 3. Calculando o impacto: antes vs depois

| Componente | Antes | Depois | Economia |
|-----------|-------|--------|---------|
| ECS Fargate NestJS | x86 `t3.medium` equiv | ARM64 `t4g.medium` equiv | 20% |
| EC2 encoding | `g4dn.xlarge` On-Demand | `g4dn.xlarge` Spot | 60% |
| RDS Postgres staging | `db.r6i.large` 24/7 | Aurora Serverless v2 4h/dia | 93% |
| ElastiCache staging | `r6g.large` 24/7 | Desligado fora do horário | 70% |
| S3 originals | Standard | Glacier IR após 7d | 82% |
| CloudWatch Logs | Sem retenção | 30d retenção + sampling | 60% |
| NAT Gateway (dev) | 1 NAT GW | fck-nat instance | 90% |
| API Gateway | REST API | HTTP API | 71% |
| Lambda | x86 512MB | ARM64 512MB | 20% |
| Compute (baseline) | On-Demand | Compute Savings Plan 1yr | 50% |

**Cenário: staging + prod + dev**

| Fase | Antes | Depois (otimizado) | Redução |
|------|-------|--------------------|---------|
| Dev/Lab | US$ 80/mês | US$ 15/mês | 81% |
| Staging | US$ 400/mês | US$ 120/mês | 70% |
| Produção (10k users) | US$ 1.415/mês | US$ 750/mês | 47% |

---

## 4. Processo de revisão contínua (FinOps loop)

### Semanal (15 minutos)
- Abrir Cost Explorer: custo ontem vs média da semana anterior.
- Verificar alerta de anomalia (Cost Anomaly Detection).
- Rodar `audit-waste.sh`.

### Mensal (1 hora)
- Comparar custo por serviço vs mês anterior.
- Rodar Compute Optimizer → implementar recomendações de right-sizing.
- Verificar S3 Storage Lens → buckets sem lifecycle.
- Revisar reservas/Savings Plans: cobertura > 70%?

### Trimestral (meio dia)
- Revisão de Savings Plans: renovar, ampliar ou reduzir.
- Auditar roles IAM com Access Analyzer (menos permissão = menos risco + menos custo oculto de auditoria).
- Benchmark de instâncias novas (Graviton nova geração disponível?).
- Revisão de arquitetura: algum serviço pode ser substituído por algo mais barato?

---

## 5. Quick wins (impacto imediato, esforço baixo)

| Ação | Impacto | Esforço |
|------|---------|---------|
| Migrar x86 → ARM64 (Graviton) em tudo | 20% Compute | Baixo |
| Lifecycle S3 nos originals | 80–90% Storage originals | Baixo |
| `abort_incomplete_multipart_upload` | Elim. storage oculto | Baixíssimo |
| Retenção em todos log groups | 40–60% CloudWatch | Baixíssimo |
| VPC Gateway Endpoints S3+DynDB | Elim. NAT traffic S3 | Baixo |
| HTTP API em vez de REST API | 71% API GW | Baixo |
| Lambda URLs para webhooks simples | 100% API GW nesse path | Baixo |
| Spot para encoding | 60% EC2 GPU | Baixo (já no módulo 10) |
| Auto-shutdown dev à noite | 60–70% dev | Baixo |
| Compute Savings Plan (após 3 meses) | 50% EC2+Fargate baseline | Baixo (1 clique) |

---

## 6. Checklist de domínio

- [ ] Migramos todas as instâncias EC2/ECS/Lambda para Graviton (ARM64).
- [ ] Spot configurado para encoding + workers batch.
- [ ] Lifecycle S3 agressivo em originals (7d → Glacier IR).
- [ ] NAT GW de dev substituído por fck-nat instance.
- [ ] VPC Gateway Endpoints para S3 e DynamoDB.
- [ ] Todos log groups têm retenção ≤ 30d.
- [ ] X-Ray com sampling 5% (100% para erros).
- [ ] API GW REST migrado para HTTP API ou Lambda URL.
- [ ] EMF para métricas custom (sem PutMetricData).
- [ ] Compute Optimizer recomendações implementadas.
- [ ] Script `audit-waste.sh` agendado semanalmente.
- [ ] Savings Plan cobrindo ≥ 70% do baseline após 3 meses.

---

## 7. Recursos

- [AWS Cost Optimization Hub](https://console.aws.amazon.com/cost-management/home#/cost-optimization-hub) — consolidador de recomendações.
- [Compute Optimizer](https://aws.amazon.com/compute-optimizer/)
- [fck-nat](https://github.com/AndrewGuenther/fck-nat) — NAT instance barata.
- [Lambda Power Tuning](https://github.com/alexcasalboni/aws-lambda-power-tuning)
- [ec2instances.info](https://ec2instances.info) — comparação de preços.
- [infracost.io](https://infracost.io) — custo no PR.
- Corey Quinn — newsletter [Last Week in AWS](https://www.lastweekinaws.com/).

---

➡️ Próximo: **Módulo 18 — Alternativas e Comparações**.
