# Cost Guard — Budget Kill-Switch

## Motivação
Proteger a conta AWS contra gastos descontrolados (loop de transcode, Lambda
mal configurada, tráfego inesperado) com um soft-stop automático e reversível.

## Arquitetura
Dois `aws_budgets_budget` (mensal $40, diário $3) — Budgets é global (us-east-1).
Eles publicam em dois tópicos SNS:
- `vod-prod-cost-alerts` → e-mail (50% / 80% / forecast do mensal).
- `vod-prod-cost-killswitch` → Lambda `vod-prod-cost-killswitch` + e-mail (100% actual de qualquer budget).

A Lambda (Python 3.12 + boto3) roda em us-east-1 e faz soft-stop em us-east-2:
1. `lambda:PutFunctionConcurrency=0` em streaming-ingest e streaming-distribution.
2. `events:DisableRule` nas regras S3→Batch e S3→ingest.
3. `batch:UpdateJobQueue=DISABLED` + termina jobs em andamento.
4. `cloudfront`: desabilita as duas distribuições (distribution + web-client).

Cada passo é isolado (uma falha não bloqueia os outros) e idempotente.

## Limitações (importante)
- **Dados de billing atrasam horas** → o stop é best-effort, não um teto rígido.
  O budget diário de $3 reduz a janela de exposição.
- Desabilitar a distribution + CloudFront **derruba o site do consumidor** — é o
  trade-off intencional (parar custo > disponibilidade).
- Propagação do CloudFront leva ~minutos.

## Recuperação (re-arm — manual)
```bash
DIST_IDS="<id-distribution> <id-web-client>" ENV=prod REGION=us-east-2 \
  bash infra/aws/scripts/cost-guard-rearm.sh
```
Remove o limite de concorrência, reabilita regras/queue/distribuições.

## Confirmação de e-mail
As subscriptions SNS de e-mail exigem **confirmação manual** (clicar no link do
e-mail "AWS Notification - Subscription Confirmation") após o primeiro `apply`.

## Teste manual
```bash
aws sns publish --topic-arn <killswitch_topic_arn> \
  --message '{"test":true}' --region us-east-1
```
Confirme o soft-stop e rode o re-arm para restaurar.
