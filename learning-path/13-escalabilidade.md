# Módulo 13 — Escalabilidade

> **Meta do módulo:** entender como cada camada do stack de streaming escala sob carga crescente e configurar scaling automático nas peças certas.

**Pré-requisitos:** módulos 08, 09, 12.

---

## 1. Conceitos

### 1.1 Escalabilidade vertical vs horizontal

| | Vertical (scale-up) | Horizontal (scale-out) |
|---|--------------------|-----------------------|
| O que é | Instância maior | Mais instâncias |
| Downtime | Geralmente sim (EC2) | Não (se projetado) |
| Custo | Não-linear | Linear |
| Teto | Existe (maior instância) | Quase ilimitado |
| Quando usar | DB single-AZ que não migrou | Stateless apps, workers |

> **Regra:** camadas stateless escalam horizontalmente. Bancos são o gargalo — cacheie antes de escalar verticalmente.

### 1.2 Auto Scaling Group (ASG)

Grupo de EC2 que mantém `desired_capacity` entre `min` e `max`. Políticas de scaling:

- **Target Tracking** — mantém métrica em valor alvo (ex: CPU = 70%). Recomendado para começar.
- **Step Scaling** — adiciona/remove N instâncias quando métrica cruza threshold.
- **Scheduled Scaling** — planeja capacidade para horários previsíveis.
- **Predictive Scaling** — ML prevê tráfego e pré-escala.

### 1.3 ECS Service Auto Scaling

Mesmo conceito, mas para tasks Fargate ou EC2:

```hcl
resource "aws_appautoscaling_target" "ecs_service" {
  max_capacity       = 20
  min_capacity       = 2
  resource_id        = "service/streaming-lab/nestjs-app"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "nestjs-cpu-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
```

### 1.4 Application Load Balancer + health checks

ALB distribui tráfego entre tasks saudáveis. Ao escalar:

1. Nova task sobe → passa health check → ALB inclui.
2. Task escalada para baixo → ALB para de enviar → `deregistration_delay` (padrão 300s) → task morre.

Configure `deregistration_delay` = 30s para apps de baixo keep-alive; 0s para jobs batch.

### 1.5 Escalabilidade do banco de dados

Banco é o gargalo mais comum. Estratégias em ordem de dificuldade:

1. **Cache em Redis** (módulo 06) — elimina 80–95% das leituras.
2. **Read replicas** — distribui leituras pesadas/BI.
3. **Connection pooling** (RDS Proxy) — previne explosão de conexões com Lambda/Fargate.
4. **Vertical scale da instância** — próximo passo se o acima não basta.
5. **Aurora Serverless v2** — escala automático de CPU/RAM.
6. **Particionamento/sharding** — raramente necessário no começo.

**DynamoDB** — escala automaticamente em on-demand. Sem knobs.

### 1.6 Encoder scale-to-zero

Worker GPU: `min=0`, `desired=0` quando fila vazia, sobe sob demanda:

```
SQS depth > 0
  → ASG scale-out (instância leva ~3-5 min para ficar pronta)
Fila vazia
  → Cooldown → ASG scale-in → min=0
```

Trade-off: 3-5 min de latência para o primeiro job de uma "friagem". Mitigar: warm pool.

**Warm Pool:** mantém N instâncias paradas (`stopped`) que ligam em ~30s.

```bash
aws autoscaling put-warm-pool --auto-scaling-group-name encoder-asg \
  --min-size 1 --pool-state Stopped
```

### 1.7 CloudFront como escudo de escala

CloudFront **absorve** a maior parte do tráfego de vídeo antes de chegar na origem:

- Segmentos HLS com `immutable` TTL → 99%+ de cache hit.
- Manifesto TTL 10s → mínimo de requisições na origem.
- `Origin Shield` → centraliza cache em região mais próxima da origem.

**A plataforma escala mais pelos usuários simultâneos de vídeo do que pela API.**

### 1.8 Padrões de resiliência

- **Circuit breaker** — quando X% das chamadas falham, para de chamar o serviço por N segundos.
- **Bulkhead** — isola partes do sistema (pool de threads/conexões separado por serviço).
- **Retry com backoff exponencial** — `2^n * 100ms + jitter`.
- **Timeout** — sempre defina; nunca espera infinita.
- **Graceful degradation** — app funciona sem cache (lento), sem search (sem filtros), etc.

---

## 2. Por que isso importa no streaming

Cargas típicas em streaming:

- **Steady state:** 100–1000 usuários simultâneos assistindo.
- **Picos:** lançamento de série, evento ao vivo → 10–100× tráfego em minutos.
- **Encoding:** assíncrono, tolerante a latência, mas volume proporcional a uploads.

Sem auto scaling:

- Pico → ECS tasks saturadas → 502/504.
- Encoding em backlog de horas → usuários não veem vídeo.
- Banco sobrecarregado → toda API lenta.

---

## 3. Laboratório prático

### 🧪 Lab 13.1 — Load test com k6

```bash
brew install k6
```

```js
// loadtest.js
import http from 'k6/http';
import { sleep, check } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 10 },   // ramp up
    { duration: '60s', target: 100 },  // carga
    { duration: '30s', target: 0 },    // ramp down
  ],
};

export default function () {
  const res = http.get('https://app.streaming.example.com/health');
  check(res, { 'status 200': r => r.status === 200 });
  sleep(1);
}
```

```bash
k6 run loadtest.js
```

Observe ECS tasks escalando no CloudWatch durante o teste.

### 🧪 Lab 13.2 — ASG Warm Pool para encoder

```hcl
resource "aws_autoscaling_warm_pool" "encoder" {
  auto_scaling_group_name = aws_autoscaling_group.encoder.name
  min_size                = 1
  max_group_prepared_capacity = 2
  pool_state              = "Stopped"

  instance_reuse_policy {
    reuse_on_scale_in = true
  }
}
```

### 🧪 Lab 13.3 — RDS Proxy para NestJS

```hcl
resource "aws_db_proxy" "postgres" {
  name                   = "streaming-postgres-proxy"
  debug_logging          = false
  engine_family          = "POSTGRESQL"
  idle_client_timeout    = 1800
  require_tls            = true
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  vpc_subnet_ids         = module.networking.private_subnets

  auth {
    auth_scheme = "SECRETS"
    iam_auth    = "DISABLED"
    secret_arn  = aws_secretsmanager_secret.db_master.arn
  }
}

resource "aws_db_proxy_default_target_group" "postgres" {
  db_proxy_name = aws_db_proxy.postgres.name
  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "postgres" {
  db_proxy_name         = aws_db_proxy.postgres.name
  target_group_name     = "default"
  db_instance_identifier = aws_db_instance.postgres.id
}
```

No NestJS, use o endpoint do proxy no lugar do endpoint direto do RDS.

### 🧪 Lab 13.4 — Scaling baseado em múltiplas métricas

Para o ECS service, quando apenas CPU não é suficiente:

```hcl
# Adicionar target tracking por RequestCount por target
resource "aws_appautoscaling_policy" "request_count" {
  name               = "nestjs-request-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_service.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_service.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_service.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 1000  # requests/task/min
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_alb.main.arn_suffix}/${aws_alb_target_group.nestjs.arn_suffix}"
    }
  }
}
```

### 🧪 Lab 13.5 — Scheduled scaling para picos previsíveis

```hcl
# Sexta às 20h BRT = 23h UTC: aumenta capacity antecipadamente
resource "aws_autoscaling_schedule" "friday_night_up" {
  scheduled_action_name  = "friday-night-scaleup"
  autoscaling_group_name = aws_autoscaling_group.nestjs.name
  cron                   = "0 23 * * FRI"
  min_size               = 5
  max_size               = 30
  desired_capacity       = 10
}

resource "aws_autoscaling_schedule" "friday_night_down" {
  scheduled_action_name  = "friday-night-scaledown"
  autoscaling_group_name = aws_autoscaling_group.nestjs.name
  cron                   = "0 6 * * SAT"
  min_size               = 2
  max_size               = 20
  desired_capacity       = 3
}
```

### 🧪 Lab 13.6 — Circuit breaker em NestJS (aws-sdk retry)

```ts
// Configuração de retry no AWS SDK v3
import { SQSClient } from '@aws-sdk/client-sqs';
import { createRetryConfig } from '@aws-sdk/middleware-retry';

const sqs = new SQSClient({
  region: 'us-east-1',
  maxAttempts: 3,
  retryMode: 'adaptive',  // backoff adaptativo
});
```

Para HTTP calls entre serviços, use `axios-retry` ou `retry` com exponential backoff:

```ts
import axiosRetry from 'axios-retry';
axiosRetry(axios, {
  retries: 3,
  retryDelay: axiosRetry.exponentialDelay,
  retryCondition: (err) => err.response?.status >= 500,
});
```

---

## 4. Padrões de escalabilidade por camada

| Camada | Scaling | Ferramenta |
|--------|---------|-----------|
| CloudFront | Automático, global | Nenhuma ação |
| ALB | Automático | Nenhuma ação |
| NestJS (ECS) | Auto scaling por CPU/requests | `aws_appautoscaling_policy` |
| Encoder workers | Scale to zero, ASG + SQS depth | `aws_autoscaling_policy` target tracking |
| Redis | Manual (resize) | ElastiCache `modify-replication-group` |
| RDS | Manual vertical + read replicas | `modify-db-instance`, `create-db-instance-read-replica` |
| DynamoDB | Automático (on-demand) | Nenhuma ação |
| S3 | Automático, ilimitado | Nenhuma ação |
| SQS | Automático, ilimitado | Nenhuma ação |

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Scale-out sem scale-in | Custo crescente | Cooldown configurado; não desabilitar scale-in |
| Scaling muito rápido (flapping) | Instâncias sobem/descem em loop | Cooldown adequado |
| Health check muito rígido | Task saudável removida | Grace period > startup time |
| Connection pool < desired_count | Conexões esgotadas com 10 tasks | Pool = MAX / desired_count |
| Banco sem read replica em pico | DB satura em SELECT pesado | Adicionar replica antes do pico |
| ECS sem deregistration delay | Conexões cortadas no scale-in | `deregistration_delay = 30` |
| Lambda concurrency ilimitada | Explosão de conexões DB | `reserved_concurrency` + RDS Proxy |
| Scaling de EC2 sem AMI atual | Nova instância com bug antigo | AMI refresh automático no ASG |

---

## 6. Checklist de domínio

- [ ] Configurei ECS auto scaling por CPU + requests por target.
- [ ] Encoder ASG vai a zero quando fila vazia.
- [ ] Fiz load test com k6 e observei scaling no CloudWatch.
- [ ] Configurei warm pool para encoder.
- [ ] Implantei RDS Proxy entre NestJS e Postgres.
- [ ] Tenho scheduled scaling para horários de pico previsíveis.
- [ ] Sei a diferença entre scale-up e scale-out.
- [ ] Entendo deregistration delay e grace period.
- [ ] Configurei retry com backoff exponencial nas chamadas críticas.

---

## 7. Recursos

**Oficiais:**
- [Auto Scaling User Guide](https://docs.aws.amazon.com/autoscaling/)
- [Application Auto Scaling](https://docs.aws.amazon.com/autoscaling/application/userguide/)
- [RDS Proxy docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.html)

**Livros / posts:**
- _Designing Data-Intensive Applications_ — Martin Kleppmann (capítulos de replicação/particionamento).
- "AWS ECS scaling deep dive" — re:Invent.
- k6 docs — [k6.io/docs](https://k6.io/docs).

---

➡️ Próximo: **Módulo 14 — FinOps & Gestão de Custos**.
