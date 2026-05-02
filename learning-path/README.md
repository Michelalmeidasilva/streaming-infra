# Learning Path — AWS Streaming Platform

Roteiro de estudo modular para aprender e subir um ecossistema completo de streaming de vídeo na AWS. Cada arquivo é autocontido e pode ser carregado no **NotebookLM** como fonte de conhecimento.

---

## Índice de módulos

| # | Arquivo | Tema | Tempo estimado |
|---|---------|------|----------------|
| 00 | [00-roadmap.md](00-roadmap.md) | Roadmap, ambiente, estratégia | 1–2h |
| 01 | [01-fundamentos-aws.md](01-fundamentos-aws.md) | Conta, CLI, IAM root, billing, free tier | 4–6h |
| 02 | [02-networking-vpc.md](02-networking-vpc.md) | VPC, subnets, SGs, NAT, Route53 | 6–10h |
| 03 | [03-iam-seguranca.md](03-iam-seguranca.md) | Roles, policies, Secrets Manager, KMS | 6–8h |
| 04 | [04-storage-cdn.md](04-storage-cdn.md) | S3, CloudFront, presigned URLs, signed cookies | 6–8h |
| 05 | [05-bancos-de-dados.md](05-bancos-de-dados.md) | RDS Postgres, DynamoDB single-table | 8–12h |
| 06 | [06-cache-redis.md](06-cache-redis.md) | ElastiCache Redis, padrões de cache | 4–6h |
| 07 | [07-mensageria.md](07-mensageria.md) | SQS, SNS, EventBridge, Amazon MQ | 6–8h |
| 08 | [08-compute.md](08-compute.md) | EC2, ECS Fargate, Lambda, API Gateway | 10–14h |
| 09 | [09-nestjs-hosting.md](09-nestjs-hosting.md) | NestJS SSR em ECS + ALB + CloudFront | 6–10h |
| 10 | [10-streaming-video-ec2-gpu.md](10-streaming-video-ec2-gpu.md) | Pipeline encoding EC2 GPU, FFmpeg, HLS/DASH | 12–16h |
| 11 | [11-terraform.md](11-terraform.md) | IaC, módulos, state remoto, workspaces | 8–12h |
| 12 | [12-observabilidade.md](12-observabilidade.md) | CloudWatch, X-Ray, logs estruturados, alertas | 6–8h |
| 13 | [13-escalabilidade.md](13-escalabilidade.md) | Auto Scaling, ALB, RDS Proxy, load test | 6–8h |
| 14 | [14-finops-custos.md](14-finops-custos.md) | Cost Explorer, Budgets, Savings Plans, FinOps | 4–6h |
| 15 | [15-cicd-pipeline.md](15-cicd-pipeline.md) | GitHub Actions, OIDC, deploy ECS, Terraform CI | 8–12h |
| 16 | [16-projeto-final.md](16-projeto-final.md) | Arquitetura completa, milestones, TCO | 30–60h |
| 17 | [17-reducao-de-custos.md](17-reducao-de-custos.md) | Quick wins, Graviton, Spot, S3 lifecycle, FinOps loop | 4–6h |
| 18 | [18-alternativas-comparacoes.md](18-alternativas-comparacoes.md) | ECS vs EKS vs Lambda, RDS vs Aurora, SQS vs Kafka, CF vs Cloudflare... | 4–6h |

**Total estimado:** 148–222 horas de estudo + laboratório.

---

## Arquitetura do projeto

```
CloudFront (CDN + WAF)
  ├── /app  → ALB → ECS Fargate (NestJS SSR)
  └── /cdn  → S3  (HLS/DASH segments)

S3 (uploads) → EventBridge → SQS → EC2 GPU Spot (FFmpeg) → S3 (encoded)
                                                           → SNS → Lambda (catalog + notif)

Dados:  RDS Postgres | DynamoDB | ElastiCache Redis
Infra:  Terraform | GitHub Actions CI/CD
Obs.:   CloudWatch | X-Ray | Budgets
```

---

## Como usar com NotebookLM

1. Crie um notebook no [NotebookLM](https://notebooklm.google.com/).
2. Adicione os arquivos `.md` como fontes (ou cole o conteúdo).
3. Sugestões de prompts:
   - *"Quais são as principais armadilhas de custo em todos os módulos?"*
   - *"Explique o fluxo completo de upload e encoding de vídeo."*
   - *"Crie um quiz de 10 perguntas sobre IAM com gabarito."*
   - *"Compare SQS vs RabbitMQ para o contexto deste projeto."*
   - *"Liste todos os comandos AWS CLI mencionados nos labs."*

---

## Pré-requisitos técnicos

```bash
# macOS
brew install awscli terraform jq git node
brew install --cask docker

# Verificar
aws --version     # >= 2.x
terraform --version  # >= 1.8
node --version    # >= 20.x
docker --version
```

---

## Sprint plan (8 semanas)

| Sprint | Módulos | Entregável |
|--------|---------|------------|
| 1 | 00, 01, 02 | VPC multi-AZ + conta segura |
| 2 | 03, 04 | S3 + CloudFront + domínio próprio |
| 3 | 05, 06 | RDS + Redis rodando |
| 4 | 07, 08 | SQS + Lambda + ECS hello-world |
| 5 | 09, 10 | NestJS + encoder GPU ponta a ponta |
| 6 | 11 | Toda infra em Terraform |
| 7 | 12, 13, 14 | Observabilidade + auto scaling + budget |
| 8 | 15, 16 | CI/CD + plataforma completa funcionando |
