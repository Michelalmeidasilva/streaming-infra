# Links dos recursos (prod) — validação

> Conta AWS `151803906541`, região principal `us-east-2` (CloudFront/Budgets/cost-guard em
> `us-east-1`). Endpoints públicos para testar + deep-links do console para inspecionar.
> Gere os valores atuais com `infra/bin/terraform -chdir=infra/aws output`.

## Endpoints públicos (abrir/testar)

| Serviço | URL | Validação rápida |
|---|---|---|
| **Web-client** | https://d3fl4gu1sp7re2.cloudfront.net | abre o app (PWA) |
| **Distribution** (catálogo) | https://d2qy6ma0p8fdhs.cloudfront.net/api/v1/videos | JSON com lista de vídeos |
| Distribution `/health` | https://d2qy6ma0p8fdhs.cloudfront.net/health | 200 |
| **Ingest** (Event Gateway) | https://kg8jhai79k.execute-api.us-east-2.amazonaws.com/ | base da API (POST `/api/v1/events` → 202) |

```bash
curl -s https://d2qy6ma0p8fdhs.cloudfront.net/api/v1/videos | head -c 200      # vídeos
curl -s -o /dev/null -w '%{http_code}\n' https://d3fl4gu1sp7re2.cloudfront.net/  # 200
curl -s -X POST https://kg8jhai79k.execute-api.us-east-2.amazonaws.com/api/v1/events \
  -H 'Content-Type: application/json' -d '{"eventType":"video.upload.started"}'   # 202
```

## Console AWS — por recurso

### Compute
- **Lambda ingest** — https://us-east-2.console.aws.amazon.com/lambda/home?region=us-east-2#/functions/streaming-ingest
- **Lambda distribution** — https://us-east-2.console.aws.amazon.com/lambda/home?region=us-east-2#/functions/streaming-distribution
- **API Gateway ingest** (`kg8jhai79k`) — https://us-east-2.console.aws.amazon.com/apigateway/main/apis/kg8jhai79k/routes?region=us-east-2
- **API Gateway distribution** (`b66m9mduye`) — https://us-east-2.console.aws.amazon.com/apigateway/main/apis/b66m9mduye/routes?region=us-east-2
- **AWS Batch** (queue/job def `vod-prod-transcode`) — https://us-east-2.console.aws.amazon.com/batch/home?region=us-east-2#jobs

### Edge / CDN
- **CloudFront distribution** (`E2M982GFYT9LMY`) — https://us-east-1.console.aws.amazon.com/cloudfront/v4/home?region=us-east-1#/distributions/E2M982GFYT9LMY
- **CloudFront web-client** (`E2AZMVM1KWQALU`) — https://us-east-1.console.aws.amazon.com/cloudfront/v4/home?region=us-east-1#/distributions/E2AZMVM1KWQALU

### Storage / dados
- **Bucket storage** (`vod-storage-2026`, `raw/` + `transcoded/`) — https://us-east-2.console.aws.amazon.com/s3/buckets/vod-storage-2026?region=us-east-2&tab=objects
- **Bucket web-client** (`vod-web-client-prod-use2`) — https://us-east-2.console.aws.amazon.com/s3/buckets/vod-web-client-prod-use2?region=us-east-2
- **Bucket tfstate** (`vod-tfstate-prod-use2`) — https://us-east-2.console.aws.amazon.com/s3/buckets/vod-tfstate-prod-use2?region=us-east-2
- **ECR** (vod-ingest/distribution/transcode) — https://us-east-2.console.aws.amazon.com/ecr/repositories?region=us-east-2

### Eventos / config
- **EventBridge rules** (`vod-prod-s3-to-batch`, `vod-prod-s3-to-ingest`) — https://us-east-2.console.aws.amazon.com/events/home?region=us-east-2#/rules
- **SSM Parameter Store** (`/vod/prod/*`) — https://us-east-2.console.aws.amazon.com/systems-manager/parameters?region=us-east-2&tab=Table
- **IAM user** (`vod-storage-svc`) — https://us-east-1.console.aws.amazon.com/iam/home#/users/details/vod-storage-svc
- **VPC** (`vpc-05f899cd38fc76efb`) — https://us-east-2.console.aws.amazon.com/vpcconsole/home?region=us-east-2#VpcDetails:VpcId=vpc-05f899cd38fc76efb

### Observabilidade
- **Dashboard CloudWatch** (`VOD-Golden-Signals-prod`) — https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards/dashboard/VOD-Golden-Signals-prod
- **Logs ingest** — https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#logsV2:log-groups/log-group/$252Faws$252Flambda$252Fstreaming-ingest
- **Logs distribution** — https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#logsV2:log-groups/log-group/$252Faws$252Flambda$252Fstreaming-distribution
- **Logs transcode (Batch)** — https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#logsV2:log-groups/log-group/$252Fvod$252Fprod$252Ftranscode

### Cost guard (us-east-1 / global)
- **Budgets** (`vod-prod-monthly` $40, `vod-prod-daily` $3) — https://us-east-1.console.aws.amazon.com/billing/home#/budgets
- **SNS topics** (`vod-prod-cost-alerts`, `vod-prod-cost-killswitch`) — https://us-east-1.console.aws.amazon.com/sns/v3/home?region=us-east-1#/topics
- **Lambda kill-switch** (`vod-prod-cost-killswitch`) — https://us-east-1.console.aws.amazon.com/lambda/home?region=us-east-1#/functions/vod-prod-cost-killswitch

## Estado atual (validado 2026-06-08)
- ✅ ingest, distribution e web-client respondendo (200/202).
- ✅ pipeline de transcode E2E funcional (segmentos DASH em `transcoded/`).
- ⚠️ SNS de e-mail (cost-guard) **PendingConfirmation** — confirmar os 2 links no e-mail.
- ⚠️ Vercel ainda aponta para o bucket `-dev` e a URL antiga do ingest (ver `cloud-deploy-apigateway.md`).
