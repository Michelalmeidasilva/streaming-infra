# Fix: preflight CORS `405` na streaming-distribution

## Sintoma

No web-client em produção (`https://d3fl4gu1sp7re2.cloudfront.net`), o `GET`
cross-site para a distribution falhava. O preflight do navegador retornava `405`:

```
OPTIONS https://d2qy6ma0p8fdhs.cloudfront.net/api/v1/videos
  origin: https://d3fl4gu1sp7re2.cloudfront.net
  access-control-request-method: GET
  access-control-request-headers: x-api-key
→ HTTP/2 405 Method Not Allowed
```

O navegador dispara o preflight porque a chamada é **cross-site** *e* usa o header
custom `x-api-key` (ambos forçam preflight). Com o preflight falhando, o `GET` real é
bloqueado pelo navegador (no `curl` o `GET` "funciona" porque curl não aplica CORS).

## Causa-raiz

O `405` é emitido pelo **router do Fiber** dentro da Lambda da distribution — não pelo
edge do CloudFront nem pelo API Gateway. Cadeia de evidências:

1. **Origem do 405 = Fiber.** A resposta do `OPTIONS` traz `content-type: text/plain`,
   `content-length: 18` (corpo `"Method Not Allowed"`, assinatura do error handler do
   Fiber) e `allow: GET, HEAD` (header `Allow` do router para uma rota só-`GET`, com
   `HEAD` automático). O `apigw-requestid` presente prova que a requisição **passou pelo
   API Gateway até a origem** (não foi barrada no edge); o `x-cache: Error from cloudfront`
   apenas repassa o erro da origem. O `allowed_methods` do CloudFront já inclui `OPTIONS`.

2. **O `Origin` chega ao Fiber** (teste diferencial): mandando `Origin`, o `OPTIONS`
   ganha `vary: Origin` e o `GET` ganha `access-control-allow-origin: *`; sem `Origin`,
   ambos somem. Logo o middleware CORS do Fiber está deployado e funcionando.

3. **O preflight não vira `204`.** No `gofiber/fiber/v2 v2.52.13`
   (`middleware/cors/cors.go`), um `OPTIONS` só é tratado como preflight (e retorna `204`)
   **se tiver o header `Access-Control-Request-Method`**. Sem ele, o middleware faz
   `c.Next()`, a requisição cai no router, não há rota `OPTIONS` para `/api/v1/videos`
   (só `GET`/`HEAD`) → `405 Allow: GET, HEAD`.

4. **Quem remove o header é o CloudFront.** O `default_cache_behavior` do CloudFront em
   `modules/distribution-lambda/main.tf` definia apenas `cache_policy_id` (managed
   *CachingDisabled*) e **nenhuma `origin_request_policy_id`**. Sem origin request policy,
   o CloudFront não encaminha `Access-Control-Request-Method`/`Access-Control-Request-Headers`
   para a origem custom. Resultado: o header de preflight chega ao Fiber ausente.

## Correção

Anexar a managed origin request policy **CORS-CustomOrigin**
(`59781a5b-3903-41f3-afcb-af62929ccde1`) ao `default_cache_behavior`. Ela encaminha
`Origin` + `Access-Control-Request-Method` + `Access-Control-Request-Headers` e **não**
encaminha `Host` (preservando o roteamento do API Gateway). Com os headers chegando, o
middleware CORS já existente no Fiber responde o preflight com `204` e devolve
`Access-Control-Allow-Methods: GET,OPTIONS` / `Access-Control-Allow-Headers:
X-API-Key,Content-Type` (configurados em `cmd/api/main.go` da distribution).

```hcl
default_cache_behavior {
  # ...
  cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled
  origin_request_policy_id = "59781a5b-3903-41f3-afcb-af62929ccde1" # Managed-CORS-CustomOrigin
}
```

### Alternativa considerada

Configurar `cors_configuration` no `aws_apigatewayv2_api` faz o HTTP API responder o
`OPTIONS` sozinho, sem depender de forwarding de header nem invocar a Lambda — mais
robusto, porém duplica a política de CORS (API Gateway + Fiber). Mantivemos o CORS num
lugar só (Fiber) e apenas destravamos o forwarding no CloudFront.

## Validação pós-apply

```bash
curl -i -X OPTIONS 'https://d2qy6ma0p8fdhs.cloudfront.net/api/v1/videos' \
  -H 'origin: https://d3fl4gu1sp7re2.cloudfront.net' \
  -H 'access-control-request-method: GET' \
  -H 'access-control-request-headers: x-api-key'
# esperado: HTTP/2 204, com access-control-allow-methods e access-control-allow-headers
```

> Caveat: o `terraform apply` depende das credenciais/kill-switch ainda pendentes na
> conta. Até o apply, a mudança está só no código.
