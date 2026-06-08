# Playback de mídia: CloudFront (OAC) sobre o bucket + modo CDN do distribution

## Sintoma

Vídeo aparecia no catálogo mas não reproduzia. Após corrigir o 500 do manifest
(`STORAGE_PROVIDER`, ver CHANGELOG), o `GET /api/v1/manifest/:id` voltava 200, mas o
player ainda falhava.

## Causa-raiz

O distribution estava em **modo presigned** (sem `CDN_BASE`). Nesse modo o
`URLBuilder` (`streaming-distribution/internal/manifest/urlbuilder.go`) presigna **apenas**
o `master.m3u8`. Mas HLS/DASH têm recursos aninhados buscados por **URL relativa**:

```
master.m3u8 → 1080p/index.m3u8 → segment-00000.m4s
```

Essas filhas resolvem contra a base do master, **sem** os query params da assinatura →
`403` no bucket privado. Confirmado: master presigned = 200, `1080p/index.m3u8` = 403. O
próprio `streaming-distribution/SPEC.md` diz que playback no browser exige modo CDN
(`CDN_BASE` setado), "presigned URLs break relative children".

Não havia CloudFront servindo o bucket de mídia (`vod-storage-2026`): só o web-client tinha
CDN, de outro bucket.

## Correção (origem S3 no CloudFront existente do distribution)

Em `modules/distribution-lambda/main.tf`, no CloudFront que já fica na frente do API
Gateway (`d2qy6ma0p8fdhs`):

- **OAC** (`aws_cloudfront_origin_access_control` tipo `s3`) — só o CloudFront lê o bucket.
- **2ª origem** S3 (`distribution-media-s3`) = `bucket_regional_domain_name`, com a OAC.
- **2 ordered_cache_behavior** (`transcoded/*`, `thumbnails/*`) → origem S3, com
  `CachingOptimized` (segmentos imutáveis) + `SimpleCORS` (ACAO no edge p/ o player buscar
  playlists/segmentos cross-origin do web-client).
- **Bucket policy** (`aws_s3_bucket_policy`) permitindo `s3:GetObject` ao principal
  `cloudfront.amazonaws.com` com `AWS:SourceArn` = esta distribution. Não é "público"
  (principal de serviço + condição), então passa pelo Block Public Access do bucket.
- **`CDN_BASE = https://<cf-domain>`** na env do Lambda → `URLBuilder` devolve URLs públicas
  do CloudFront; as filhas relativas resolvem na mesma distribution, roteadas p/ o S3.

O default behavior continua indo p/ o API Gateway (rotas `/api/*`, `/health`); só
`transcoded/*` e `thumbnails/*` vão p/ o S3.

### Sem ciclo no Terraform

`aws_lambda_function` passa a referenciar `aws_cloudfront_distribution.this.domain_name`, mas
o CloudFront depende de `aws_apigatewayv2_api.this` (atributo `api_endpoint`, que não depende
do Lambda) e do S3 — não do Lambda. Logo `lambda → cloudfront → {api, s3}` é acíclico.

## CORS da mídia: player manda `x-api-key` (CloudFront Functions)

Mesmo com a mídia no CDN, o playback ainda dava **403**. O player (Shaka, via
`packages/player/src/VodPlayer.ts`) injeta o header custom `x-api-key` em **toda**
requisição, inclusive nos arquivos públicos do CDN. Consequências:

1. Header custom + cross-origin ⇒ o browser faz **preflight CORS** (`OPTIONS`) na mídia. O
   S3 (via OAC) recusa o `OPTIONS` assinado → 403. Adicionar a origem ao CORS do bucket
   **não** resolve (S3 não processa o preflight de requisição assinada por OAC — verificado).
2. A managed `SimpleCORS` (response headers policy) **não aplica** o
   `access-control-allow-origin` na resposta do GET quando o `x-api-key` está presente
   (verificado: mesmo arquivo/MISS, sem o header tem `ACAO: *`, com o header não tem). Sem
   ACAO na resposta real, o browser bloqueia mesmo com o preflight OK.

**Fix (edge):** duas CloudFront Functions nos behaviors `transcoded/*`/`thumbnails/*`:
- `media_cors.js` (viewer-request): se `OPTIONS`, responde `204` com os headers de CORS
  (`access-control-allow-*`) — preflight resolvido no edge, sem tocar no S3.
- `media_cors_response.js` (viewer-response): injeta `access-control-allow-origin: *` em todo
  GET/HEAD (não roda na resposta gerada pelo preflight). Determinístico, independe do
  x-api-key. A `SimpleCORS` foi removida dos behaviors (CORS 100% nas functions, sem ACAO
  duplicado).

**Fix de raiz (cleanup recomendado):** o web-client não deveria mandar `x-api-key` em
recursos do CDN (só nas chamadas à API `/api/v1/*`). Hoje o filtro do Shaka adiciona o header
em tudo. Removendo/escopando esse filtro, não há preflight nenhum e a `SimpleCORS` voltaria a
bastar — mas exige rebuild+redeploy do web-client (repo separado).

## Caveats

- **Cache do manifest (Redis, `CACHE_TTL=300`)**: após setar `CDN_BASE`, o manifest pode
  servir as URLs presigned antigas por até ~5 min (entrada cacheada) antes de refrescar p/
  URLs de CDN. Esperar o TTL ou invalidar a chave `manifest:<id>`.
- **Propagação do CloudFront**: novos origin/behaviors levam alguns minutos até `Deployed`.

## Validação

```bash
B=https://d2qy6ma0p8fdhs.cloudfront.net/transcoded/<id>/hls
curl -o /dev/null -w '%{http_code}\n' "$B/master.m3u8"        # 200
curl -o /dev/null -w '%{http_code}\n' "$B/1080p/index.m3u8"   # 200 (antes: 403)
curl -o /dev/null -w '%{http_code}\n' "$B/1080p/segment-00000.m4s"  # 200
# manifest devolvendo URLs de CDN (não presigned) após o TTL do cache:
curl -s '.../api/v1/manifest/<id>' -H 'x-api-key: pk_prod' | python3 -c 'import sys,json;print(json.load(sys.stdin)["hls"])'
```
