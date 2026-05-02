# Módulo 12 — Observabilidade (CloudWatch, X-Ray, Alertas)

> **Meta do módulo:** enxergar tudo que acontece na plataforma — logs estruturados, métricas personalizadas, dashboards, alertas e tracing distribuído.

**Pré-requisitos:** módulos 08, 09.

---

## 1. Conceitos

### 1.1 Os três pilares da observabilidade

| Pilar | O que é | AWS |
|-------|---------|-----|
| **Logs** | Eventos discretos com contexto | CloudWatch Logs |
| **Métricas** | Valores numéricos no tempo | CloudWatch Metrics |
| **Traces** | Rastreamento de uma requisição | AWS X-Ray |

> 🧠 **Modelo mental:**
> - Logs = "o que aconteceu".
> - Métricas = "quantas vezes / quão rápido".
> - Traces = "onde perdeu tempo / onde quebrou dentro da requisição".

### 1.2 CloudWatch Logs

**Conceitos:**
- **Log group** = coleção lógica (ex: `/ecs/nestjs-app`).
- **Log stream** = sequência contínua de eventos (ex: um container).
- **Log event** = linha individual com timestamp.
- **Retenção** = quantos dias guardar (0 = forever; US$ 0.03/GB/mês armazenado).

**Logs Insights** = SQL-like para queries:

```sql
fields @timestamp, @message
| filter @message like "ERROR"
| sort @timestamp desc
| limit 50
```

### 1.3 CloudWatch Metrics

- **Namespace** = agrupamento (ex: `AWS/ECS`, `AWS/SQS`, `Streaming/App`).
- **Metric** = nome do que mede (ex: `CPUUtilization`, `EncodingJobDuration`).
- **Dimension** = filtro (ex: `ServiceName=nestjs-app`).
- **Statistics** = `Average`, `Sum`, `Max`, `p99`, `p95`.
- **Period** = janela de agregação (60s mínimo para standard; 1s com high-resolution).

**Custom metrics:** `PutMetricData` API (US$ 0.30/métrica/mês).

### 1.4 CloudWatch Alarms

Aciona ação quando métrica cruza threshold:

- **Actions:** SNS → email/SMS/Lambda, AutoScaling, EC2 action.
- **Estados:** `OK`, `ALARM`, `INSUFFICIENT_DATA`.
- **Composite alarms:** combina múltiplos alarms com AND/OR.

### 1.5 AWS X-Ray

Distributed tracing — segue uma requisição por todos os serviços.

**Conceitos:**
- **Trace** = jornada completa de uma requisição.
- **Segment** = parte do serviço (ex: "nestjs-app processou em 45ms").
- **Subsegment** = detalhe interno (ex: "query Postgres demorou 32ms").
- **Annotations** = chave/valor indexados (filtráveis).
- **Metadata** = dados extras não indexados.
- **Groups** = filtros de traces.
- **Service map** = diagrama automático das dependências.

**Integração NestJS/Node.js:**

```ts
import AWSXRay from 'aws-xray-sdk';
import https from 'https';

AWSXRay.captureHTTPsGlobal(https);
AWSXRay.captureAWS(require('@aws-sdk/client-s3'));

// No middleware do NestJS:
app.use(AWSXRay.express.openSegment('streaming-api'));
// ... routes ...
app.use(AWSXRay.express.closeSegment());
```

### 1.6 CloudWatch Container Insights

Para ECS/EKS: coleta métricas de CPU, memória, rede, disco por task e container.

```bash
aws ecs update-cluster-settings --cluster streaming-lab \
  --settings name=containerInsights,value=enabled
```

Custo adicional mas vale em produção.

### 1.7 Synthetic monitoring (CloudWatch Canaries)

Scripts que simulam usuários. Ex: "a cada 5 minutos, faz login e inicia um vídeo. Alarma se falhar ou demorar > 3s".

---

## 2. Por que isso importa no streaming

**Problemas que observabilidade detecta antes do usuário reclamar:**

- Player bufferando → TTFB alto em CloudFront → cache hit caiu → origem sobrecarregada.
- Fila de encoding crescendo → workers não estão consumindo → ASG não escalou (métrica SQS).
- Taxa de erros 5xx no NestJS subindo → trace X-Ray mostra query Postgres lenta.
- Custo explodindo → métrica de egress CloudFront disparou → alguém abriu vídeo em loop.

**Golden Signals (SRE Google):**

| Signal | Métrica AWS |
|--------|-------------|
| **Latency** | ALB `TargetResponseTime`, API GW `IntegrationLatency` |
| **Traffic** | ALB `RequestCount`, CF `Requests` |
| **Errors** | ALB `HTTPCode_Target_5XX_Count`, ECS `TaskFailedToStart` |
| **Saturation** | ECS `CPUUtilization`, ElastiCache `EngineCPUUtilization` |

---

## 3. Laboratório prático

### 🧪 Lab 12.1 — Logs estruturados no NestJS

```ts
// logger.ts
import { Injectable, LoggerService } from '@nestjs/common';

@Injectable()
export class StructuredLogger implements LoggerService {
  private log(level: string, message: string, context?: string, extra?: object) {
    process.stdout.write(JSON.stringify({
      level,
      message,
      context,
      timestamp: new Date().toISOString(),
      ...extra,
    }) + '\n');
  }
  error(msg: string, trace?: string, ctx?: string) { this.log('ERROR', msg, ctx, { trace }); }
  warn(msg: string, ctx?: string)  { this.log('WARN', msg, ctx); }
  debug(msg: string, ctx?: string) { this.log('DEBUG', msg, ctx); }
  verbose(msg: string, ctx?: string) { this.log('VERBOSE', msg, ctx); }
}
```

```ts
// main.ts
app.useLogger(new StructuredLogger());
```

CloudWatch recebe JSON → Logs Insights consegue filtrar por campos:

```sql
fields @timestamp, level, message, context
| filter level = "ERROR"
| stats count() by context
```

### 🧪 Lab 12.2 — Log retention via Terraform

```hcl
resource "aws_cloudwatch_log_group" "nestjs_app" {
  name              = "/ecs/nestjs-app"
  retention_in_days = 30
  tags = { Name = "nestjs-app-logs" }
}

resource "aws_cloudwatch_log_group" "encoder" {
  name              = "/ec2/encoder"
  retention_in_days = 14
}
```

> Sem retenção definida = logs acumulam para sempre. **Sempre defina.**

### 🧪 Lab 12.3 — Custom metric: duração do encoding

```js
// No worker (após encoding)
import { CloudWatchClient, PutMetricDataCommand } from '@aws-sdk/client-cloudwatch';

const cw = new CloudWatchClient({ region: 'us-east-1' });

await cw.send(new PutMetricDataCommand({
  Namespace: 'Streaming/Encoder',
  MetricData: [{
    MetricName: 'EncodingDurationSeconds',
    Value: durationSeconds,
    Unit: 'Seconds',
    Dimensions: [{ Name: 'Environment', Value: process.env.ENVIRONMENT }],
  }, {
    MetricName: 'JobsCompleted',
    Value: 1,
    Unit: 'Count',
  }],
}));
```

### 🧪 Lab 12.4 — Alarm na DLQ do encoder

```hcl
resource "aws_cloudwatch_metric_alarm" "encoder_dlq" {
  alarm_name          = "encoder-dlq-not-empty"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Mensagens na DLQ do encoder - investigar falhas"

  dimensions = { QueueName = aws_sqs_queue.encoder_dlq.name }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_sns_topic" "alerts" {
  name = "streaming-alerts"
}
resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

### 🧪 Lab 12.5 — Dashboard CloudWatch

```hcl
resource "aws_cloudwatch_dashboard" "streaming" {
  dashboard_name = "streaming-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "ECS CPU Utilization"
          period = 60
          metrics = [["AWS/ECS","CPUUtilization","ServiceName","nestjs-app","ClusterName","streaming-lab"]]
          view   = "timeSeries"
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Encoder Queue Depth"
          period = 60
          metrics = [["AWS/SQS","ApproximateNumberOfMessagesVisible","QueueName","streaming-dev-encoder-jobs"]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "CloudFront Cache Hit Rate"
          period = 300
          metrics = [["AWS/CloudFront","CacheHitRate","DistributionId","EABCD","Region","Global"]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "ALB 5xx Errors"
          period = 60
          metrics = [["AWS/ApplicationELB","HTTPCode_Target_5XX_Count","LoadBalancer","..."]]
          stat   = "Sum"
        }
      }
    ]
  })
}
```

### 🧪 Lab 12.6 — X-Ray no NestJS

```bash
npm install aws-xray-sdk
```

```ts
// app.module.ts
import * as AWSXRay from 'aws-xray-sdk';
import { INestApplication } from '@nestjs/common';

export function configureXRay(app: INestApplication) {
  if (process.env.NODE_ENV === 'production') {
    AWSXRay.config([AWSXRay.plugins.ECSPlugin]);
    app.use(AWSXRay.express.openSegment('streaming-api'));
    // registrar após rotas
  }
}
```

Task definition — precisa da política `AWSXRayDaemonWriteAccess` na task role.

### 🧪 Lab 12.7 — Log Insights: queries úteis

```sql
-- Erros nas últimas 1h
fields @timestamp, level, message, context
| filter level = "ERROR"
| sort @timestamp desc
| limit 100

-- P99 de duração por endpoint
fields @timestamp, responseTime, path
| filter ispresent(responseTime)
| stats pct(responseTime, 99) as p99 by path
| sort p99 desc

-- Taxa de erro por minuto
filter level = "ERROR"
| stats count() as errorCount by bin(1m)
| sort @timestamp desc

-- Top 10 usuários por volume de requests
fields userId
| filter ispresent(userId)
| stats count() as reqs by userId
| sort reqs desc
| limit 10
```

### 🧪 Lab 12.8 — CloudWatch Agent no EC2 encoder

Para métricas de GPU e disco:

```bash
# Instala agent
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/streaming-config.json << 'EOF'
{
  "metrics": {
    "metrics_collected": {
      "disk": { "measurement": ["used_percent"], "resources": ["/"] },
      "nvidia_gpu": {
        "measurement": ["utilization_gpu", "utilization_memory", "temperature_gpu"]
      }
    },
    "namespace": "Streaming/Encoder"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [{
          "file_path": "/var/log/encoder/*.log",
          "log_group_name": "/ec2/encoder",
          "log_stream_name": "{instance_id}"
        }]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/streaming-config.json
```

---

## 4. SLIs, SLOs e Error Budgets

**SLI** = Service Level Indicator (ex: "99.5% das requisições respondem em < 500ms").
**SLO** = Service Level Objective (meta: "SLI > 99.5% em janela de 30 dias").
**Error budget** = quanto você pode errar (0.5% de 30 dias = ~3.6h de downtime).

Para streaming:

| SLI | Meta |
|-----|------|
| Player start time < 3s | 99.9% |
| API `/catalog` < 200ms | 99.5% |
| Encoding concluído em < 15min | 98% |
| Uptime do app | 99.9% |

Alarmes → violação de SLO → on-call.

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Log sem retenção | TB acumulando, US$ 100s/mês | Sempre `retention_in_days` |
| Métricas de alta resolução (1s) | 3× mais caro | Só onde latência importa |
| Sem alarme em DLQ | Bugs silenciosos | Alarme mandatório em toda DLQ |
| Log em formato texto puro | Queries Insights lentas | Sempre JSON estruturado |
| X-Ray sem sampling rule | Custo alto em prod (US$ 5/M traces) | Sampling 5–10% + 100% erros |
| Container Insights sem necessidade | US$ 2–5/nó/mês extra | Só em prod |
| Dashboard com muitos widgets | Lento e caro (US$ 3/dashboard/mês) | 1 dashboard por stack |

**Custos típicos:**
- CloudWatch Logs: US$ 0.03/GB ingerido + US$ 0.03/GB armazenado/mês.
- Custom metrics: US$ 0.30/métrica/mês (primeiras 10.000 grátis).
- Alarmes: US$ 0.10/alarme/mês (primeiros 10 grátis).
- X-Ray: US$ 5/1M traces registrados (primeiros 100k grátis).

---

## 6. Checklist de domínio

- [ ] NestJS emitindo logs em JSON estruturado para CloudWatch.
- [ ] Todos os log groups têm retenção configurada.
- [ ] Tenho métricas custom para duração de encoding.
- [ ] Tenho alarme na DLQ do encoder + e-mail.
- [ ] Dashboard com os 4 golden signals do meu app.
- [ ] X-Ray configurado no NestJS com sampling.
- [ ] Sei escrever query Logs Insights para encontrar erros.
- [ ] CloudWatch Agent coletando métricas de disco/GPU no EC2.
- [ ] Defini pelo menos 2 SLOs para a plataforma.

---

## 7. Recursos

**Oficiais:**
- [CloudWatch User Guide](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/)
- [X-Ray Developer Guide](https://docs.aws.amazon.com/xray/latest/devguide/)
- [Container Insights](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html)

**Livros:**
- _Observability Engineering_ — Charity Majors et al. (O'Reilly).
- _Site Reliability Engineering_ — Google (gratuito online).

**Ferramentas:**
- `aws-embedded-metrics` (Node SDK) — envia métricas estruturadas em logs sem API extra.
- `Datadog`, `New Relic`, `Honeycomb` — alternativas comerciais quando CloudWatch não basta.

---

➡️ Próximo: **Módulo 13 — Escalabilidade**.
