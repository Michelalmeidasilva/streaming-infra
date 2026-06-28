# Fix: `403` no upload presigned (CORS do bucket S3)

## Sintoma

Em produção, o `streaming-platform-upload` (`https://streaming-platform-upload.vercel.app`)
fazia o PUT direto para o bucket via presigned URL e recebia **`403`**:

```
PUT https://vod-storage-2026.s3.us-east-2.amazonaws.com/raw/<uuid>/<file>.mp4?X-Amz-...
  Referer: https://streaming-platform-upload.vercel.app/
→ 403 Forbidden
```

## Causa-raiz

**Não é a assinatura nem permissão IAM.** O mesmo presigned URL via `curl -X PUT` grava o
objeto normalmente (`200 OK`, `ETag` retornado) — a credencial tem `s3:PutObject` e a
assinatura está correta.

O `403` é do **preflight CORS do S3**. Um PUT cross-origin não é "simple request", então o
navegador dispara um `OPTIONS` para o objeto antes do PUT. O bucket `vod-storage-2026` tinha
CORS com `AllowedOrigins` apenas para dev local:

```json
"AllowedOrigins": ["http://127.0.0.1:3000", "http://localhost:3000"]
```

A origem de produção `https://streaming-platform-upload.vercel.app` não estava na lista, então
o S3 respondia `403` ao `OPTIONS` e o navegador bloqueava o PUT.

A origem do problema no IaC: `cors_allowed_origins` estava **comentado** no
`aws/terraform.tfvars`, então o `module.storage_s3` aplicava o default (só localhost) de
`modules/storage-s3/variables.tf`.

## Correção

`aws/terraform.tfvars`:

```hcl
cors_allowed_origins = [
  "https://streaming-platform-upload.vercel.app",
  "http://localhost:3000",
  "http://127.0.0.1:3000",
]
```

`terraform apply -target=module.storage_s3.aws_s3_bucket_cors_configuration.this`. O CORS de
bucket S3 é efetivo imediatamente (sem propagação tipo CloudFront).

> Ao trocar o domínio da Vercel (preview/branch deploys usam subdomínios diferentes), some
> os novos hosts ao `cors_allowed_origins` ou use o domínio custom estável.

## Validação

```bash
curl -i -X OPTIONS 'https://vod-storage-2026.s3.us-east-2.amazonaws.com/raw/<uuid>/<file>.mp4' \
  -H 'Origin: https://streaming-platform-upload.vercel.app' \
  -H 'Access-Control-Request-Method: PUT'
# esperado: HTTP/1.1 200 OK + Access-Control-Allow-Origin: https://streaming-platform-upload.vercel.app
```
