storage_bucket_name = "vod-storage-2026"
alert_email         = "michelalmeida.dev@gmail.com"

cors_allowed_origins = [
  "https://streaming-platform-upload.vercel.app",
  "http://localhost:3000",
  "http://127.0.0.1:3000",
]

# Secrets (mongodb_uri, rabbitmq_url, redis_url) são lidos via TF_VAR_*
# Exportar antes de aplicar: set -a && source ../.env && set +a
