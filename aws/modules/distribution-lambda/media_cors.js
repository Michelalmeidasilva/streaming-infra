// CloudFront Function (viewer-request) para os behaviors de mídia (transcoded/*, thumbnails/*).
// O player do web-client (Shaka) injeta o header custom `x-api-key` em TODA requisição,
// inclusive nos arquivos públicos do CDN. Header custom + cross-origin ⇒ o browser dispara
// um preflight CORS (OPTIONS). A origem S3 (via OAC) responde 403 ao OPTIONS assinado, então
// o preflight falha e o vídeo não carrega. Esta função responde o preflight no edge com os
// headers de CORS, sem tocar no S3. Os GET reais seguem para o S3 e recebem ACAO pela
// response headers policy (SimpleCORS) do behavior.
function handler(event) {
  var req = event.request;
  if (req.method === 'OPTIONS') {
    return {
      statusCode: 204,
      statusDescription: 'No Content',
      headers: {
        'access-control-allow-origin': { value: '*' },
        'access-control-allow-methods': { value: 'GET, HEAD, OPTIONS' },
        'access-control-allow-headers': { value: '*' },
        'access-control-max-age': { value: '3000' },
        'cache-control': { value: 'no-store' }
      }
    };
  }
  return req;
}
