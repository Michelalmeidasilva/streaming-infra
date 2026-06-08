#!/usr/bin/env bash
# Reverte o soft-stop do cost-guard kill-switch. MANUAL — rode só quando for seguro voltar.
# Uso: ENV=prod REGION=us-east-2 DIST_IDS="E111 E222" bash infra/aws/scripts/cost-guard-rearm.sh
set -euo pipefail

ENV="${ENV:-prod}"
REGION="${REGION:-us-east-2}"

LAMBDAS=("streaming-ingest" "streaming-distribution")
RULES=("vod-${ENV}-s3-to-batch" "vod-${ENV}-s3-to-ingest")
QUEUE="vod-${ENV}-transcode"
DISTS=()  # IDs das distribuições CloudFront — exporte DIST_IDS="E111 E222"
read -r -a DISTS <<< "${DIST_IDS:-}"

echo ">> Removendo limite de concorrência das Lambdas"
for fn in "${LAMBDAS[@]}"; do
  aws lambda delete-function-concurrency --function-name "$fn" --region "$REGION" || true
done

echo ">> Reabilitando regras EventBridge"
for r in "${RULES[@]}"; do
  aws events enable-rule --name "$r" --region "$REGION" || true
done

echo ">> Reabilitando Batch job queue"
aws batch update-job-queue --job-queue "$QUEUE" --state ENABLED --region "$REGION" || true

echo ">> Reabilitando distribuições CloudFront"
for d in "${DISTS[@]}"; do
  etag=$(aws cloudfront get-distribution-config --id "$d" --query 'ETag' --output text)
  aws cloudfront get-distribution-config --id "$d" --query 'DistributionConfig' > /tmp/cf-"$d".json
  python3 -c "import json,sys; c=json.load(open('/tmp/cf-$d.json')); c['Enabled']=True; json.dump(c, open('/tmp/cf-$d.json','w'))"
  aws cloudfront update-distribution --id "$d" --distribution-config file:///tmp/cf-"$d".json --if-match "$etag"
done

echo ">> Re-arm concluído. Confirme no console que tudo voltou."
