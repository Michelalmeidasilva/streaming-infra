#!/usr/bin/env bash
# Auditoria read-only dos recursos AWS existentes (bucket S3 + streaming-ingest).
# Uso:
#   BUCKET=<nome-bucket> INGEST_FN=<nome-lambda> REGION=us-east-2 bash aws-audit.sh
# Se BUCKET/INGEST_FN não forem passados, o script tenta descobrir por heurística.
set -euo pipefail

REGION="${REGION:-us-east-2}"
BUCKET="${BUCKET:-}"
INGEST_FN="${INGEST_FN:-}"

echo "== AWS account =="
aws sts get-caller-identity --output table

# ---- Descoberta (best-effort) ----
if [[ -z "$BUCKET" ]]; then
  echo "== Buckets candidatos (filtro 'vod'/'stream') =="
  aws s3api list-buckets --query "Buckets[?contains(Name, 'vod') || contains(Name, 'stream')].Name" --output text || true
  echo ">> Defina BUCKET=<nome> e rode de novo para auditar o bucket."
fi

if [[ -n "$BUCKET" ]]; then
  echo "== S3: $BUCKET =="
  echo "-- Region --";        aws s3api get-bucket-location --bucket "$BUCKET" --output text || echo "(erro)"
  echo "-- Encryption --";    aws s3api get-bucket-encryption --bucket "$BUCKET" --output json 2>/dev/null || echo "NENHUMA"
  echo "-- Public Access --"; aws s3api get-public-access-block --bucket "$BUCKET" --output json 2>/dev/null || echo "NENHUM"
  echo "-- Versioning --";    aws s3api get-bucket-versioning --bucket "$BUCKET" --output json 2>/dev/null || echo "(vazio = Disabled)"
  echo "-- Lifecycle --";     aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json 2>/dev/null || echo "NENHUMA"
  echo "-- Notification --";  aws s3api get-bucket-notification-configuration --bucket "$BUCKET" --output json 2>/dev/null || echo "NENHUMA"
  echo "-- CORS --";          aws s3api get-bucket-cors --bucket "$BUCKET" --output json 2>/dev/null || echo "NENHUMA"
fi

# ---- streaming-ingest ----
if [[ -z "$INGEST_FN" ]]; then
  echo "== Lambdas candidatas (filtro 'ingest') =="
  aws lambda list-functions --region "$REGION" \
    --query "Functions[?contains(FunctionName, 'ingest')].FunctionName" --output text || true
  echo ">> Defina INGEST_FN=<nome> para auditar a função."
fi

if [[ -n "$INGEST_FN" ]]; then
  echo "== Lambda: $INGEST_FN =="
  aws lambda get-function-configuration --region "$REGION" --function-name "$INGEST_FN" \
    --query "{Name:FunctionName, Region:'$REGION', PackageType:PackageType, Role:Role, Memory:MemorySize, Timeout:Timeout}" \
    --output table || echo "(função não encontrada em $REGION)"
  echo "-- Env vars (chaves) --"
  aws lambda get-function-configuration --region "$REGION" --function-name "$INGEST_FN" \
    --query "Environment.Variables" --output json 2>/dev/null | jq 'keys' || echo "(sem env)"
fi

echo
echo "== Comandos de import sugeridos (revise antes de rodar) =="
if [[ -n "$BUCKET" ]]; then
  cat <<EOF
infra/bin/terraform -chdir=infra/aws import 'module.storage_s3.aws_s3_bucket.this' "$BUCKET"
EOF
fi
echo ">> ingest: import só no Plano 2, após o módulo ingest-lambda existir."
