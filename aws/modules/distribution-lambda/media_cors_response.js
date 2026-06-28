// CloudFront Function (viewer-response) para os behaviors de mídia.
// Injeta o ACAO em toda resposta de GET/HEAD da mídia. Necessário porque, quando o player
// manda o header custom `x-api-key`, a managed response headers policy (SimpleCORS) deixa de
// aplicar o `access-control-allow-origin` na resposta — e o browser exige ACAO na resposta
// real (não só no preflight). Fazendo no edge fica determinístico, independente do x-api-key.
// (Não roda em respostas geradas pela viewer-request, ex.: o 204 do preflight OPTIONS.)
function handler(event) {
  var res = event.response;
  res.headers['access-control-allow-origin'] = { value: '*' };
  res.headers['access-control-expose-headers'] = { value: '*' };
  return res;
}
