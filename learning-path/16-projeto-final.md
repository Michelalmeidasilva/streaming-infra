# Módulo 16 — Projeto Final: Plataforma de Streaming Completa

> **Meta do módulo:** integrar todos os módulos anteriores em uma plataforma funcional de VOD (Video on Demand) com upload, encoding, catálogo, autenticação, pagamento e entrega via CDN.

**Pré-requisitos:** TODOS os módulos anteriores.

---

## 1. Visão geral da arquitetura

```
┌─────────────────────────────────────────────────────────────────────────┐
│                              EDGE / CDN                                 │
│  CloudFront (CDN global + WAF + signed cookies + certificado TLS)       │
│    ├── /app/* → ALB (NestJS SSR)                                        │
│    └── /cdn/* → S3 (vídeos HLS/DASH encodados + assets estáticos)       │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
┌────────────────────────────────────▼────────────────────────────────────┐
│                           PLANO DE CONTROLE                             │
│  ECS Fargate (2+ tasks)                                                 │
│  ┌─ NestJS App ──────────────────────────────────────────────────────┐  │
│  │  /auth  /users  /catalog  /videos  /upload  /player-token        │  │
│  └──────────┬────────────────────────────────────────────────────────┘  │
│             │                                                           │
│  ALB (HTTPS 443, path routing)                                          │
└─────────────┬───────────────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────────────────┐
│                         PLANO DE DADOS                                  │
│  RDS Postgres     ElastiCache Redis     DynamoDB                        │
│  (usuários,       (sessão, catálogo     (catálogo vídeo,                │
│   billing,         cache, rate-limit)    watch history)                 │
│   upload jobs)                                                          │
└─────────────────────────────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────────────────┐
│                      PLANO DE PROCESSAMENTO                             │
│  S3 (uploads/) → EventBridge → SQS (encoder-jobs)                       │
│                                     │                                   │
│                             EC2 GPU Spot (g4dn.xlarge)                  │
│                             ASG scale-to-zero                           │
│                             FFmpeg NVENC → HLS/DASH                     │
│                                     │                                   │
│                             S3 (encoded/) → CloudFront                  │
│                                     │                                   │
│                             SNS (job-events)                            │
│                               ├── SQS → Lambda (update DynamoDB)        │
│                               └── SQS → Lambda (send push/email)        │
└─────────────────────────────────────────────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────────────────────────────┐
│                          PLANO DE SUPORTE                               │
│  CloudWatch (logs, métricas, dashboards, alarmes)                       │
│  X-Ray (distributed tracing)                                            │
│  GitHub Actions CI/CD (deploy ECS + Terraform + AMI)                   │
│  Budgets + Cost Anomaly Detection                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Componentes detalhados

### 2.1 NestJS App (SSR + API)

**Módulos NestJS:**
- `AuthModule` — Cognito integration, JWT, refresh tokens.
- `UsersModule` — CRUD, planos, billing.
- `VideosModule` — catálogo, metadados, DynamoDB.
- `UploadModule` — presigned URLs S3, registro de job no Postgres.
- `PlayerModule` — gera CloudFront signed cookies por autenticação.
- `CatalogModule` — listas, busca, caching Redis.
- `HealthModule` — `/health` endpoint.

### 2.2 Fluxo de upload de vídeo

```
1. Usuário autenticado → POST /videos/upload-url
2. NestJS:
   a. Verifica plano/quota
   b. Gera presigned PUT S3 (5min TTL) para s3://uploads/{jobId}/{filename}
   c. INSERT em upload_jobs (status=pending)
   d. Retorna { uploadUrl, jobId }
3. Navegador → PUT direto para S3 (sem passar pelo backend)
4. S3 → EventBridge "Object Created" → SQS encoder-jobs
5. Worker EC2 GPU:
   a. Recebe mensagem com s3Key
   b. Download input
   c. FFmpeg NVENC → HLS 360p + 720p + 1080p
   d. Upload segments para s3://encoded/{jobId}/
   e. Upload master manifest
   f. DELETE mensagem SQS
   g. Publica SNS "finished" com { jobId, manifestKey }
6. Lambda catalog-update:
   a. PUT em DynamoDB VIDEO#{jobId} status=published
   b. UPDATE upload_jobs status=ready, output_prefix
7. Lambda notif:
   a. Lê e-mail do usuário no Postgres
   b. SES envia "Seu vídeo está pronto!"
```

### 2.3 Fluxo de reprodução

```
1. Usuário → GET /videos/{videoId}
2. NestJS:
   a. Verifica autenticação + plano ativo
   b. Busca metadados (Redis hit ou DynamoDB)
   c. Gera CloudFront signed cookies (1h)
   d. Retorna { videoUrl, cookies }
3. Browser define cookies CloudFront
4. HLS.js → GET https://cdn.streaming.example.com/encoded/{jobId}/index.m3u8
   (CloudFront valida cookie → S3 origin)
5. Player escolhe rendition por bandwidth
6. Playback em loop de segmentos
```

---

## 3. Estrutura do repositório

```
streaming-platform/
├── app/                        # NestJS application
│   ├── src/
│   │   ├── auth/
│   │   ├── users/
│   │   ├── videos/
│   │   ├── upload/
│   │   ├── player/
│   │   ├── catalog/
│   │   ├── health/
│   │   └── main.ts
│   ├── test/
│   ├── Dockerfile
│   └── package.json
├── encoder/                    # Worker EC2 GPU
│   ├── worker.js
│   ├── ffmpeg-presets.js
│   ├── package.json
│   └── ami/
│       └── encoder.pkr.hcl     # Packer AMI
├── infra/                      # Terraform
│   ├── modules/
│   │   ├── networking/
│   │   ├── rds/
│   │   ├── elasticache/
│   │   ├── s3-buckets/
│   │   ├── sqs-topics/
│   │   ├── ecs-service/
│   │   ├── encoder-asg/
│   │   └── cloudfront/
│   ├── environments/
│   │   ├── dev.tfvars
│   │   └── prod.tfvars
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── lambdas/
│   ├── catalog-update/
│   └── send-notification/
└── .github/
    └── workflows/
        ├── deploy-app.yml
        ├── terraform.yml
        └── encoder-ami.yml
```

---

## 4. Milestones de implementação

### Sprint 1 — Fundação (semana 1-2)
- [ ] Repositório Git criado.
- [ ] AWS Account com MFA + budgets configurado.
- [ ] Backend Terraform (S3 + DynamoDB lock).
- [ ] VPC multi-AZ via módulo Terraform.
- [ ] Todos os security groups definidos.
- [ ] Secrets Manager com placeholders.

### Sprint 2 — Dados (semana 2-3)
- [ ] RDS Postgres em subnet privada (via Terraform).
- [ ] Schema SQL aplicado (migrations com Flyway/TypeORM).
- [ ] DynamoDB tabela catálogo single-table.
- [ ] ElastiCache Redis replication group.
- [ ] Teste de conectividade entre subnets.

### Sprint 3 — Messaging + Lambda (semana 3-4)
- [ ] S3 buckets (uploads, encoded, assets).
- [ ] SQS encoder-jobs + DLQ.
- [ ] SNS job-events.
- [ ] EventBridge rule: S3 Object Created → SQS.
- [ ] Lambda catalog-update funcional.
- [ ] Lambda send-notification funcional.

### Sprint 4 — NestJS App (semana 4-5)
- [ ] Dockerfile multi-stage buildando.
- [ ] App rodando localmente com `.env` apontando para recursos AWS de dev.
- [ ] Todos os endpoints funcionando em dev.
- [ ] Testes unitários passando.
- [ ] Pushed para ECR.

### Sprint 5 — ECS + ALB + CloudFront (semana 5-6)
- [ ] ECS service com 2 tasks em prod.
- [ ] ALB com health check passando.
- [ ] CloudFront distribution na frente do ALB.
- [ ] Custom domain com ACM.
- [ ] HTTPS funcionando.
- [ ] Auto scaling configurado.

### Sprint 6 — Encoder (semana 6-7)
- [ ] AMI do encoder buildada com Packer.
- [ ] Launch template com g4dn.xlarge Spot.
- [ ] ASG com scale-to-zero.
- [ ] Worker consumindo SQS e encodando vídeos.
- [ ] Scaling por SQS queue depth.
- [ ] CloudFront servindo vídeos com signed cookies.
- [ ] Player HLS.js funcionando no browser.

### Sprint 7 — Observabilidade + Pipeline (semana 7-8)
- [ ] Todos os logs em JSON estruturado.
- [ ] Log groups com retenção.
- [ ] CloudWatch dashboard com golden signals.
- [ ] Alarmes em DLQ + 5xx + CPU.
- [ ] X-Ray ativo no NestJS.
- [ ] GitHub Actions: CI/CD de app + Terraform + AMI.
- [ ] Branch protection configurado.

### Sprint 8 — Hardening + FinOps (semana 8)
- [ ] WAF na frente do CloudFront (OWASP rules).
- [ ] GuardDuty habilitado.
- [ ] IAM Access Analyzer sem findings.
- [ ] Infracost no pipeline de Terraform.
- [ ] Auto-shutdown em dev.
- [ ] Custo mensal documentado e dentro do orçamento.
- [ ] Runbook de on-call criado.

---

## 5. Testes de validação ponta a ponta

### Teste 1 — Upload e encoding

```bash
# 1. Login na plataforma (ou curl com Bearer token)
TOKEN=$(curl -s -X POST https://app.streaming.example.com/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"test@example.com","password":"senha"}' | jq -r '.access_token')

# 2. Obter presigned URL
RESPONSE=$(curl -s -X POST https://app.streaming.example.com/videos/upload-url \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"filename":"test.mp4","contentType":"video/mp4"}')
UPLOAD_URL=$(echo $RESPONSE | jq -r '.uploadUrl')
JOB_ID=$(echo $RESPONSE | jq -r '.jobId')

# 3. Upload direto para S3
curl -X PUT "$UPLOAD_URL" -H 'Content-Type: video/mp4' --data-binary @test.mp4

# 4. Aguardar encoding (monitora DynamoDB)
until [ "$(aws dynamodb get-item --table-name streaming-catalog \
  --key "{\"PK\":{\"S\":\"VIDEO#$JOB_ID\"},\"SK\":{\"S\":\"METADATA\"}}" \
  --query 'Item.status.S' --output text)" == "published" ]; do
  echo "Aguardando encoding..."; sleep 10
done
echo "Vídeo pronto!"

# 5. Obter player token
PLAYER=$(curl -s -X GET "https://app.streaming.example.com/videos/$JOB_ID/player-token" \
  -H "Authorization: Bearer $TOKEN")
MANIFEST_URL=$(echo $PLAYER | jq -r '.manifestUrl')

# 6. Testar manifest
curl -s "$MANIFEST_URL" | head -5  # deve retornar #EXTM3U
```

### Teste 2 — Resiliência

```bash
# Simula falha de AZ: muda security group de subnet-priva para bloquear tráfego
# Verifica se app continua servindo de subnet-privb
# Desfaz após teste

# Force ECS task restart
aws ecs update-service --cluster streaming-prod --service nestjs-app --force-new-deployment
# App deve continuar disponível (rolling deploy)

# Simula fila cheia de jobs
for i in $(seq 1 10); do
  aws sqs send-message --queue-url $QUEUE_URL \
    --message-body "{\"jobId\":\"load-test-$i\",\"s3Key\":\"uploads/test.mp4\"}"
done
# Observe ASG escalando no CloudWatch
```

### Teste 3 — Carga

```bash
k6 run --vus 100 --duration 5m loadtest.js
# Expectativa: p99 < 500ms, 0% errors 5xx
```

---

## 6. Estimativa de custo para produção

### Cenário: 10.000 usuários ativos, 500 vídeos/mês novos

| Componente | Config | Custo/mês |
|-----------|--------|-----------|
| ECS Fargate NestJS | 0.5vCPU/1GB × 3 tasks avg | US$ 45 |
| ALB | baseline | US$ 20 |
| CloudFront | 5 TB egress + 100M reqs | US$ 450 |
| S3 | 1 TB encoded + 200 GB uploads | US$ 25 |
| RDS Postgres | `r7g.large` multi-AZ | US$ 350 |
| ElastiCache Redis | `r7g.large` × 2 | US$ 380 |
| EC2 GPU encoding | `g4dn.xlarge` Spot × 20h/dia | US$ 100 |
| Lambda (notif, catalog) | 1M reqs | US$ 5 |
| SQS / SNS / EB | 10M msgs | US$ 8 |
| CloudWatch | logs + métricas | US$ 30 |
| ACM / Route53 | | US$ 2 |
| **Total** | | **~US$ 1.415/mês** |

> Otimizações possíveis: Compute Savings Plan (−60% ECS), Reserved ElastiCache (−40%), CloudFront commit deal em escala.

---

## 7. Runbook básico de on-call

### Sintoma: player travando em buffer

1. Verificar CloudFront cache hit rate no dashboard.
2. Se < 85%: verificar Cache-Control dos segmentos (`immutable` presente?).
3. Verificar TTFB da origem (ALB `TargetResponseTime`).
4. Verificar ElastiCache `GetTypeMisses` (manifesto não cacheado?).

### Sintoma: vídeo não fica pronto após upload

1. `aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names ApproximateNumberOfMessages`
2. Se fila tem mensagens mas workers não consomem: verificar ASG desired capacity.
3. Se ASG está escalando mas instance não vira InService: verificar logs CloudWatch `/ec2/encoder`.
4. Se mensagens foram para DLQ: verificar conteúdo no console SQS → identificar erro.

### Sintoma: 5xx subindo no ALB

1. CloudWatch: `HTTPCode_Target_5XX_Count` por target group.
2. CloudWatch Logs Insights: `filter level="ERROR"` nos últimos 15min.
3. X-Ray: Service Map → identifica gargalo.
4. Se Postgres: verificar `CPUUtilization` e `DatabaseConnections`.
5. Se Redis: verificar `EngineCPUUtilization`.
6. Rollback: `aws ecs update-service --task-definition nestjs-app:N-1 --force-new-deployment`.

---

## 8. Próximos passos além do projeto

Após ter a plataforma funcionando:

1. **Autenticação** — Cognito User Pools ou Auth0 (SSO, OAuth2, MFA).
2. **Pagamentos** — Stripe + webhook → Lambda atualiza plano no RDS.
3. **Busca** — OpenSearch Service para full-text search no catálogo.
4. **Recomendações** — SageMaker ou simplesmente DynamoDB sorted sets de "similares".
5. **Live streaming** — Amazon IVS (serverless) ou MediaLive (mais controle).
6. **DRM** — Widevine + FairPlay para conteúdo licenciado.
7. **Multi-região** — Route53 geolocation routing + DynamoDB Global Tables.
8. **Analytics** — Kinesis Data Firehose → S3 → Athena → QuickSight.

---

## 9. Checklist final

- [ ] Plataforma sobe do zero com `terraform apply` em < 20 minutos.
- [ ] Upload → encoding → reprodução funciona ponta a ponta.
- [ ] Player reproduzindo em 360p, 720p e 1080p com ABR.
- [ ] Conteúdo protegido por signed cookies (URL sem cookie retorna 403).
- [ ] ECS auto scaling funciona (load test prova).
- [ ] Encoder ASG vai a zero quando fila vazia.
- [ ] Rolling deploy sem downtime via GitHub Actions.
- [ ] CloudWatch dashboard com golden signals.
- [ ] Alarmes disparando por e-mail em DLQ + 5xx.
- [ ] Custo mensal dentro do orçamento estimado.
- [ ] Todos os recursos tagueados com Project + Environment.
- [ ] IAM Access Analyzer sem findings críticos.

---

## 10. Recursos finais

**Arquiteturas de referência:**
- [AWS Reference Architecture: VOD](https://aws.amazon.com/solutions/implementations/video-on-demand-on-aws/)
- [AWS Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/)
- [AWS Streaming Media Blog](https://aws.amazon.com/blogs/media/)

**Comunidades:**
- [AWS re:Post](https://repost.aws/) — fórum técnico.
- [Serverless Land](https://serverlessland.com/) — patterns de event-driven.
- [CDK Patterns](https://cdkpatterns.com/) — arquiteturas em código.

---

**Parabéns — você terminou o learning path. Agora construa.**
