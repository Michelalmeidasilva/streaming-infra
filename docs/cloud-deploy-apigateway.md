# Cloud deploy — entrypoints via API Gateway (não Function URL)

> Documenta a arquitetura real de exposição das Lambdas na conta AWS de prod, e por que
> ela difere do design original (Function URL pública). Aplicado em 2026-06-08.

## Contexto / problema

O design original (`aws/RUNBOOK.md`) expunha `streaming-ingest` e `streaming-distribution`
como **Lambda Function URL** com `authorization_type = "NONE"` (pública), o distribution
atrás de CloudFront. **A conta AWS de prod (`151803906541`, limitada/nova — concurrency=10)
bloqueia Function URL pública/anônima**: toda chamada anônima recebe `403 AccessDeniedException`,
mesmo com a resource policy `Allow * lambda:InvokeFunctionUrl` correta e sem Organization/SCP.

Verificado:
- Function URL `NONE` → 403 em tudo (inclusive URL recém-criada).
- Function URL `AWS_IAM` + requisição assinada → chega na função (200/404 do app).
- CloudFront **OAC** → Lambda URL `AWS_IAM` (config textbook-correta) → **também 403** após 15min.

## Arquitetura aplicada

| Serviço | Exposição | Motivo |
|---|---|---|
| `streaming-ingest` | **API Gateway HTTP API** (público) | Tem chamadores externos sem credencial AWS (Vercel, EventBridge API Destination). API Gateway não sofre o bloqueio de Function URL. |
| `streaming-distribution` | **CloudFront → API Gateway HTTP API** | Precisa de cache de manifests no edge (CloudFront) + endpoint que funciona (API Gateway). |
| `streaming-web-client` | S3 privado + CloudFront (OAC de S3 funciona) | Estático. |

- Os módulos `ingest-lambda` e `distribution-lambda` usam `aws_apigatewayv2_api`/`integration`
  (AWS_PROXY, payload v2.0)/`route ($default)`/`stage ($default, auto_deploy)` +
  `aws_lambda_permission` (principal `apigateway.amazonaws.com`).
- O `aws-lambda-web-adapter` da imagem entende o payload v2.0 do HTTP API igual à Function URL.
- O output `function_url` de cada módulo passou a ser a invoke_url do stage (ingest com `/`
  final via `trimsuffix`), então o wiring downstream (events API Destination, Batch
  `EVENT_GATEWAY_URL`) não mudou.

## Outros ajustes do deploy real

- **Imagens Lambda**: buildar com `docker build --provenance=false --sbom=false`. O buildkit
  do Docker 29 anexa attestation/OCI image index → `InvalidParameterValueException: The image
  manifest ... media type ... is not supported` no `CreateFunction`.
- **distribution / S3 creds**: as env reservadas `AWS_ACCESS_KEY_ID/SECRET` saíram do Lambda
  (são injetadas pela execution role). `s3_adapter.go` passou a incluir `AWS_SESSION_TOKEN` no
  `NewStaticV4`. Adicionada policy `s3:GetObject/ListBucket` na role.
- **transcode / Batch**: a Dockerfile trocou `ENTRYPOINT ["streaming-transcode"]` por
  `CMD ["streaming-transcode"]` — senão o `command` do Batch (`transcode-local <key>`) era
  anexado ao entrypoint e rodava o worker RabbitMQ (que morria sem broker). Ver
  `streaming-transcode/CHANGELOG.md`.

## Pendências conhecidas

- **Vercel** (`streaming-platform-upload`): atualizar a env do ingest para a URL do API Gateway
  (`https://kg8jhai79k.execute-api.us-east-2.amazonaws.com/` — confira o output atual com
  `terraform output ingest_function_url`).
- **Cold start do ingest**: a Lambda mantém conexão AMQP/Mongo; na primeira rajada de eventos
  (ex. do job Batch) os `POST /events` podem retornar 500 até a conexão estabelecer. Avaliar
  retry no chamador ou provisioned concurrency.
- **E2E completo**: um upload sintético (objeto colocado direto em `raw/`) transcoda e sobe
  para `transcoded/`, mas o `PATCH /upload-state/{id}` retorna 404 (não há registro criado pelo
  upload). Para SUCCEEDED de ponta a ponta, subir pelo `streaming-platform-upload`.
