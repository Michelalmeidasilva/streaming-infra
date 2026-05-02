# Módulo 09 — Hosting de aplicação NestJS (SSR)

> **Meta do módulo:** subir uma aplicação NestJS com server-side rendering (ou API) na AWS usando ECS Fargate atrás de ALB, com CloudFront na frente para cache de assets estáticos, TLS e custom domain.

**Pré-requisitos:** módulos 02, 03, 04, 08.

---

## 1. Arquitetura alvo

```
Internet
  │
  ▼
Route53 (alias) → CloudFront distribution
                       │
                       ├─ /assets/*, /_next/static/* → S3 (assets estáticos)
                       │
                       └─ /* (SSR, APIs) → ALB
                                            │
                                       ECS Fargate service
                                         (NestJS containers)
                                            │
                              ┌─────────────┴──────────────────┐
                              RDS Postgres   ElastiCache Redis   Secrets Manager
```

**Por que CloudFront na frente do ALB?**

- Cache de assets CSS/JS no edge → TTFB menor, custo menor.
- TLS termina no CloudFront (certificado ACM).
- Proteção WAF global.
- CDN de HTML cacheável (ex: home page, catálogo).
- Você não expõe o DNS do ALB diretamente.

---

## 2. Conceitos — NestJS na AWS

### 2.1 NestJS em containers

NestJS é Node.js. Para rodar em ECS Fargate:

1. **Dockerfile** — build multi-stage (build + runtime).
2. **ECR** (Elastic Container Registry) — repositório privado de imagens.
3. **ECS Task Definition** — onde configura imagem, CPU, RAM, env vars, secrets, logs.
4. **ECS Service** — desired count, health check, ALB integration, rolling deploy.

### 2.2 ECR — Container Registry

```bash
# Cria repositório
aws ecr create-repository --repository-name streaming/nestjs-app

# Login local
aws ecr get-login-password | docker login \
  --username AWS --password-stdin \
  $ACCOUNT.dkr.ecr.us-east-1.amazonaws.com
```

### 2.3 Task definition: secrets e env vars

**Nunca coloque secrets em variáveis de ambiente em texto puro no task definition.** Use referência do Secrets Manager:

```json
"secrets": [
  {
    "name": "DATABASE_URL",
    "valueFrom": "arn:aws:secretsmanager:us-east-1:123:secret:streaming/db/url"
  }
]
```

A role `executionRoleArn` precisa de `secretsmanager:GetSecretValue` nesse ARN.

### 2.4 Health check para NestJS

Endpoint obrigatório:

```ts
// health.controller.ts
@Controller('health')
export class HealthController {
  @Get()
  check() {
    return { status: 'ok', ts: new Date().toISOString() };
  }
}
```

No ALB target group: path `/health`, 2xx, threshold 2 healthy / 3 unhealthy.

### 2.5 CloudFront à frente do ALB

- **Origin 1** — S3 para `/assets/*` e `/_next/static/*` (se Next.js) ou `/public/*`.
- **Origin 2** — ALB para tudo o mais.
- Comportamento: path pattern `/assets/*` → Origin 1 com longo TTL. Default (`/*`) → ALB.
- **Custom origin header** no ALB: `X-CF-Secret: <token>`. ALB listener rule verifica header → bloqueia acesso direto ao ALB.

---

## 3. Laboratório prático

### 🧪 Lab 9.1 — Dockerfile multi-stage NestJS

```dockerfile
# Build stage
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production=false
COPY . .
RUN npm run build

# Runtime stage
FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./

# Non-root
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
USER appuser

EXPOSE 3000
CMD ["node", "dist/main.js"]
```

```bash
docker build -t streaming/nestjs-app .
docker run -p 3000:3000 streaming/nestjs-app
curl localhost:3000/health
```

### 🧪 Lab 9.2 — Push para ECR

```bash
IMAGE="$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/streaming/nestjs-app"

docker tag streaming/nestjs-app $IMAGE:latest
docker push $IMAGE:latest

# Com hash de commit para immutable tags
GIT_SHA=$(git rev-parse --short HEAD)
docker tag streaming/nestjs-app $IMAGE:$GIT_SHA
docker push $IMAGE:$GIT_SHA
```

> 💡 Em produção, sempre use tag imutável (hash de commit). `latest` é anti-padrão.

### 🧪 Lab 9.3 — Task definition + service ECS

```bash
# Execution role para ECS
aws iam create-role --role-name ecsTaskExecutionRole --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Permissão extra para Secrets Manager
aws iam put-role-policy --role-name ecsTaskExecutionRole --policy-name secrets-access \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"arn:aws:secretsmanager:us-east-1:'$ACCOUNT':secret:streaming/*"}]
  }'

# Task role (o que a app pode fazer)
aws iam create-role --role-name nestjs-app-task-role --assume-role-policy-document '{
  "Version":"2012-10-17",
  "Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
# Adicione policies específicas: s3:GetObject em bucket de assets, etc.

# Log group
aws logs create-log-group --log-group-name /ecs/nestjs-app

# Task definition
cat > task-definition.json <<EOF
{
  "family": "nestjs-app",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole",
  "taskRoleArn": "arn:aws:iam::$ACCOUNT:role/nestjs-app-task-role",
  "containerDefinitions": [{
    "name": "app",
    "image": "$ACCOUNT.dkr.ecr.us-east-1.amazonaws.com/streaming/nestjs-app:latest",
    "portMappings": [{"containerPort": 3000, "protocol": "tcp"}],
    "environment": [
      {"name": "PORT", "value": "3000"},
      {"name": "REDIS_HOST", "value": "<elasticache-primary-endpoint>"}
    ],
    "secrets": [
      {"name": "DATABASE_URL", "valueFrom": "arn:aws:secretsmanager:us-east-1:$ACCOUNT:secret:streaming/db/url"}
    ],
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:3000/health || exit 1"],
      "interval": 15, "timeout": 5, "retries": 3, "startPeriod": 30
    },
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/nestjs-app",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "app"
      }
    }
  }]
}
EOF

aws ecs register-task-definition --cli-input-json file://task-definition.json

# ECS Service (assume ALB/target group já criados - Lab 8.6)
aws ecs create-service \
  --cluster streaming-lab \
  --service-name nestjs-app \
  --task-definition nestjs-app \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIV_A,$PRIV_B],securityGroups=[$SG_APP],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_ARN,containerName=app,containerPort=3000" \
  --health-check-grace-period-seconds 60 \
  --deployment-configuration "minimumHealthyPercent=50,maximumPercent=200"
```

### 🧪 Lab 9.4 — Rolling deploy

Quando fizer nova versão:

```bash
# Registra nova task definition
aws ecs register-task-definition --cli-input-json file://task-definition-v2.json

# Atualiza o service (zero-downtime rolling)
aws ecs update-service \
  --cluster streaming-lab \
  --service nestjs-app \
  --task-definition nestjs-app:2 \
  --force-new-deployment

# Acompanha deploy
aws ecs wait services-stable --cluster streaming-lab --services nestjs-app
```

### 🧪 Lab 9.5 — CloudFront na frente do ALB

```bash
# 1. Cria CloudFront distribution com ALB como origin
cat > cf-distribution.json <<EOF
{
  "Comment": "Streaming NestJS app",
  "DefaultCacheBehavior": {
    "TargetOriginId": "alb-origin",
    "ViewerProtocolPolicy": "redirect-to-https",
    "CachePolicyId": "4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
    "OriginRequestPolicyId": "b689b0a8-53d0-40ab-baf2-68738e2966ac",
    "AllowedMethods": {
      "Quantity": 7,
      "Items": ["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
      "CachedMethods": {"Quantity":2,"Items":["GET","HEAD"]}
    }
  },
  "CacheBehaviors": {
    "Quantity": 1,
    "Items": [{
      "PathPattern": "/public/*",
      "TargetOriginId": "s3-assets",
      "ViewerProtocolPolicy": "redirect-to-https",
      "CachePolicyId": "658327ea-f89d-4fab-a63d-7e88639e58f6",
      "Compress": true
    }]
  },
  "Origins": {
    "Quantity": 2,
    "Items": [
      {
        "Id": "alb-origin",
        "DomainName": "<alb-dns-name>",
        "CustomOriginConfig": {
          "HTTPSPort": 443,
          "OriginProtocolPolicy": "https-only",
          "OriginSSLProtocols": {"Quantity":1,"Items":["TLSv1.2"]}
        },
        "CustomHeaders": {
          "Quantity": 1,
          "Items": [{"HeaderName":"X-CF-Secret","HeaderValue":"meu-token-secreto"}]
        }
      },
      {
        "Id": "s3-assets",
        "DomainName": "$BUCKET.s3.us-east-1.amazonaws.com",
        "S3OriginConfig": {"OriginAccessIdentity": ""}
      }
    ]
  },
  "Enabled": true,
  "PriceClass": "PriceClass_100",
  "ViewerCertificate": {
    "ACMCertificateArn": "$CERT_ARN",
    "SSLSupportMethod": "sni-only",
    "MinimumProtocolVersion": "TLSv1.2_2021"
  },
  "Aliases": {"Quantity":1,"Items":["app.streaming.example.com"]}
}
EOF
```

### 🧪 Lab 9.6 — Auto Scaling do ECS Service

```bash
# Registra o resource
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --resource-id service/streaming-lab/nestjs-app \
  --scalable-dimension ecs:service:DesiredCount \
  --min-capacity 2 --max-capacity 10

# Policy: CPU tracking
aws application-autoscaling put-scaling-policy \
  --policy-name cpu-target-tracking \
  --service-namespace ecs \
  --resource-id service/streaming-lab/nestjs-app \
  --scalable-dimension ecs:service:DesiredCount \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {"PredefinedMetricType": "ECSServiceAverageCPUUtilization"},
    "ScaleInCooldown": 300, "ScaleOutCooldown": 60
  }'
```

---

## 4. Configuração NestJS para produção

### Graceful shutdown

```ts
// main.ts
app.enableShutdownHooks();
```

ECS manda SIGTERM → NestJS drena conexões → process exits. Sem isso, requisições em voo são cortadas.

### Config com validação

```ts
// config/configuration.ts
import Joi from 'joi';

export const validationSchema = Joi.object({
  PORT: Joi.number().default(3000),
  DATABASE_URL: Joi.string().uri().required(),
  REDIS_HOST: Joi.string().required(),
  NODE_ENV: Joi.string().valid('development', 'production', 'test').default('production'),
});
```

### Variáveis de ambiente via Secrets Manager no app

```ts
// Alternativa ao task definition secrets: carregar em runtime
const client = new SecretsManagerClient({});
const { SecretString } = await client.send(
  new GetSecretValueCommand({ SecretId: 'streaming/db/url' })
);
```

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Container sem health check | ECS não sabe se app travou | Endpoint `/health` + health check no task definition |
| Image tag `latest` em prod | Deploy inconsistente | Tag imutável (git SHA) |
| Secrets em `environment` (texto puro) | Vazamento em logs do CloudTrail | `secrets` com ARN do Secrets Manager |
| ALB exposto diretamente | Bypass do WAF/CloudFront | Custom header + listener rule no ALB |
| `desired-count=1` em prod | Falha de task = downtime | Mínimo 2 tasks em 2 AZs |
| Sem graceful shutdown | Conexões cortadas no deploy | `app.enableShutdownHooks()` |
| Node.js single-threaded com CPU pesada | Latência alta | Mova processamento para worker, use cluster mode |
| Falta de `NODE_ENV=production` | Tree-shaking e cache do NestJS não ativam | Sempre set no task definition |

**Custos típicos:**
- 2 tasks ECS Fargate 0.5 vCPU / 1 GB: ~US$ 28/mês.
- ALB: ~US$ 20/mês base.
- CloudFront na frente: depende do tráfego (US$ 0.085/GB).
- Total stack simples: ~US$ 50–80/mês sem tráfego expressivo.

---

## 6. Checklist de domínio

- [ ] Tenho Dockerfile multi-stage otimizado para NestJS.
- [ ] Imagem publicada no ECR com tag imutável (git SHA).
- [ ] Task definition com secrets via Secrets Manager (não variável texto puro).
- [ ] ECS service rodando 2+ tasks em AZs diferentes.
- [ ] Health check funcionando no ALB (2xx no `/health`).
- [ ] Rolling deploy sem downtime funcionou.
- [ ] CloudFront na frente do ALB com custom header de segurança.
- [ ] Auto scaling configurado por CPU.
- [ ] Graceful shutdown habilitado no NestJS.
- [ ] Sei o custo mensal do stack ECS+ALB+CloudFront.

---

## 7. Recursos

**Oficiais:**
- [ECS + Fargate Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/)
- [NestJS docs](https://docs.nestjs.com/)
- [Docker multi-stage builds](https://docs.docker.com/build/building/multi-stage/)

**Ferramentas:**
- `@aws-sdk/client-ecs` — para deploy programático via CLI.
- `AWS Copilot` — abstraição de alto nível para ECS (`copilot init`).
- `finch` — alternativa Docker para build local no macOS.

---

➡️ Próximo: **Módulo 10 — Pipeline de transcodificação em EC2 GPU**.
