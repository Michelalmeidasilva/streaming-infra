# Módulo 04 — Storage & CDN (S3 + CloudFront)

> **Meta do módulo:** dominar S3 (object storage) e CloudFront (CDN) — a espinha dorsal de qualquer plataforma de conteúdo, especialmente vídeo.

**Pré-requisitos:** módulos 01, 03.

---

## 1. Conceitos

### 1.1 O que é S3

**Amazon S3 (Simple Storage Service)** = object storage durável, escalável e barato.

- **Bucket** = container global. Nome **único na AWS inteira** (todos os clientes).
- **Object** = arquivo (até 5 TB). Tem `Key` (nome/caminho), `Body`, `Metadata`, `ETag`.
- **Não é sistema de arquivos.** Não tem diretórios reais — `videos/2026/x.mp4` é só uma key. O console finge ser uma árvore.
- **Durabilidade**: 99.999999999% (11 noves) = praticamente impossível perder objeto bem armazenado.
- **Disponibilidade**: 99.99% no Standard.

> 🧠 **Modelo mental:** S3 é um Google Drive global, com chave/valor, sem estrutura de pastas, e cobrado por GB armazenado + por requisição + por egress.

### 1.2 Storage classes (e quando usar cada uma)

| Classe | US$/GB/mês | Latência | Quando |
|--------|-----------|----------|--------|
| **Standard** | 0.023 | ms | Padrão; arquivos quentes |
| **Standard-IA** (Infrequent Access) | 0.0125 | ms | Acessado < 1x/mês |
| **One Zone-IA** | 0.01 | ms | Cópias secundárias, regenerável |
| **Intelligent-Tiering** | varia | ms | Quando padrão de acesso é desconhecido |
| **Glacier Instant Retrieval** | 0.004 | ms | Arquivamento que precisa de leitura rápida raramente |
| **Glacier Flexible Retrieval** | 0.0036 | minutos a 12h | Backup |
| **Glacier Deep Archive** | 0.00099 | 12h | Compliance / "guardar por lei" |

> 💡 **Em streaming:** vídeo original (mezzanine) → Glacier Flexible. Vídeo encodado para entrega → Standard. Thumbnails → Standard. Logs → IA depois Glacier.

### 1.3 Lifecycle policies

Regras automáticas para mover ou deletar objetos com base em idade.

```json
{
  "Rules": [{
    "ID": "video-archive",
    "Status": "Enabled",
    "Filter": { "Prefix": "originals/" },
    "Transitions": [
      { "Days": 30, "StorageClass": "STANDARD_IA" },
      { "Days": 90, "StorageClass": "GLACIER" }
    ],
    "Expiration": { "Days": 3650 }
  }]
}
```

### 1.4 Versioning

- Toda mudança em uma key cria nova **version**, em vez de sobrescrever.
- **Delete** vira "delete marker" (recuperável).
- Use **MFA Delete** em buckets críticos.
- Combine com **Object Lock** para WORM (write-once-read-many) — compliance.

### 1.5 Encryption

| Modo | Quem gerencia chave | Quando |
|------|--------------------|--------|
| **SSE-S3** | AWS | Default; OK para a maioria |
| **SSE-KMS** | Sua KMS key | Auditoria, multi-conta, key rotation |
| **SSE-C** | Você manda a chave em cada request | Raríssimo |
| **Client-side** | App cripta antes de subir | Dados ultra-sensíveis |

Desde 2023, **encryption é default** em buckets novos (SSE-S3). Você pode forçar SSE-KMS via bucket policy.

### 1.6 Acesso a objetos

- **Bucket policy** (resource policy JSON) — quem pode mexer no bucket.
- **ACLs** — modelo legado, **desabilite** ("Object Ownership: Bucket owner enforced").
- **Block Public Access** — switch de segurança no nível da conta + bucket. **Mantenha LIGADO** sempre que possível.
- **Presigned URLs** — URL temporária assinada para upload/download (essencial em streaming!).

#### Presigned URLs

```bash
# Upload presigned válido por 5 minutos
aws s3 presign s3://my-bucket/uploads/file.mp4 \
  --expires-in 300

# Em código (Node.js)
const url = s3.getSignedUrl('putObject', {
  Bucket: 'my-bucket',
  Key: `uploads/${userId}/${filename}`,
  Expires: 300,
  ContentType: 'video/mp4'
});
```

> O cliente recebe a URL, faz `PUT` direto para S3 sem passar pelo seu backend. **Padrão em qualquer upload de vídeo grande.**

### 1.7 S3 Transfer Acceleration vs Multipart Upload

- **Multipart Upload** — divide arquivo grande em partes e sobe em paralelo. **Use sempre acima de 100 MB.**
- **Transfer Acceleration** — usa edge locations CloudFront para upload mais rápido cross-region. ~US$ 0.04/GB extra. Só vale para uploads internacionais grandes.

### 1.8 O que é CloudFront

**Amazon CloudFront** = CDN global. ~600 edge locations. Coloca seu conteúdo perto do usuário.

- **Origin** = onde está o conteúdo real (S3 bucket, ALB, EC2, qualquer HTTPS).
- **Distribution** = configuração da CDN (origins, behaviors, certs).
- **Behavior** = regra "este path → este origin com estas configs" (cache, headers, métodos).
- **Cache Policy / Origin Request Policy / Response Headers Policy** — controles modulares (modo novo, melhor que "legacy cache settings").

### 1.9 Por que CDN para streaming

1. **Latência** — usuário em Tokyo baixa de edge em Tokyo, não de S3 em us-east-1.
2. **Banda barata** — egress CloudFront ~US$ 0.085/GB (até 10 TB) é mais barato que **egress S3 direto** (US$ 0.09/GB) e tem volume tier que cai para US$ 0.02/GB em escala.
3. **Cache** — manifesto HLS é pequeno e quente, segments de vídeo são imutáveis. Cache hit > 95% comum.
4. **Origin shield** — camada extra de cache regional reduz hits no origin.
5. **Signed URLs / Cookies** — controle de acesso a vídeo pago.

### 1.10 OAC (Origin Access Control)

Sucessor do OAI. Permite que **só o CloudFront** acesse seu bucket S3 (bucket fica privado para internet).

```json
// Bucket policy gerada automaticamente
{
  "Effect": "Allow",
  "Principal": { "Service": "cloudfront.amazonaws.com" },
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::my-bucket/*",
  "Condition": {
    "StringEquals": {
      "AWS:SourceArn": "arn:aws:cloudfront::123:distribution/EABCD..."
    }
  }
}
```

### 1.11 Signed URLs e Signed Cookies (CloudFront)

- **Signed URL** = uma URL com assinatura, expira em N minutos. Para 1 arquivo.
- **Signed Cookie** = cookie assinado válido para um padrão de URLs. Bom para HLS (manifesto + dezenas de segments).
- Você assina com **chave RSA** que cadastra como "Public key + Key group" no CloudFront.

---

## 2. Por que isso importa no streaming

Pipeline de vídeo típico:

```
Cliente upload  ── presigned PUT ──▶  S3 (uploads/)
                                       │
                                       ▼
                                 EventBridge
                                       │
                                       ▼
                              MediaConvert job
                                       │
                                       ▼
                            S3 (encoded/abc/index.m3u8)
                                       │
                              CloudFront (com OAC + signed cookies)
                                       │
                                       ▼
                                  Player no navegador
```

Decisões de S3+CloudFront determinam:

- **Custo de banda** (CloudFront price class, cache TTL).
- **Latência ao primeiro frame** (TTFB) → cache de manifesto.
- **Pirataria/compartilhamento** → signed cookies + DRM.
- **Custo de storage** → lifecycle policies para rascunhos e originals.

---

## 3. Laboratório prático

### 🧪 Lab 4.1 — Bucket + objeto + presigned URL

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
BUCKET="streaming-lab-$ACCOUNT"

# Cria bucket privado em us-east-1
aws s3api create-bucket --bucket $BUCKET --region us-east-1

# Bloqueia público
aws s3api put-public-access-block --bucket $BUCKET \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Habilita versioning
aws s3api put-bucket-versioning --bucket $BUCKET \
  --versioning-configuration Status=Enabled

# Sobe um arquivo
echo "hello streaming" > test.txt
aws s3 cp test.txt s3://$BUCKET/

# Gera presigned para download (1 minuto)
aws s3 presign s3://$BUCKET/test.txt --expires-in 60
# Cole no navegador e baixe
```

### 🧪 Lab 4.2 — Lifecycle policy

```bash
cat > lifecycle.json <<EOF
{
  "Rules": [
    {
      "ID": "transition-old-to-IA",
      "Status": "Enabled",
      "Filter": { "Prefix": "logs/" },
      "Transitions": [
        { "Days": 30, "StorageClass": "STANDARD_IA" },
        { "Days": 90, "StorageClass": "GLACIER" }
      ],
      "Expiration": { "Days": 365 }
    },
    {
      "ID": "abort-incomplete-multipart",
      "Status": "Enabled",
      "Filter": {},
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket $BUCKET --lifecycle-configuration file://lifecycle.json
```

> 💡 A regra `AbortIncompleteMultipartUpload` é **obrigatória em todo bucket**. Multiparts órfãos cobram storage invisível.

### 🧪 Lab 4.3 — Distribution CloudFront com OAC servindo S3 privado

**Console** (mais simples):

1. **CloudFront → Create distribution**.
2. **Origin domain** = seu bucket (`streaming-lab-XXX.s3.us-east-1.amazonaws.com`).
3. **Origin access** = "Origin access control settings (recommended)".
4. **Create new OAC**.
5. CloudFront gera uma **policy** para colar no bucket — clique "Copy policy", vá ao bucket → **Permissions → Bucket policy** → cole.
6. **Default cache behavior**:
   - Viewer protocol policy: **Redirect HTTP to HTTPS**.
   - Allowed HTTP methods: `GET, HEAD`.
   - Cache policy: **CachingOptimized**.
   - Origin request policy: **CORS-S3Origin** (se for usar do navegador).
7. **Settings**:
   - Price class: **Use only US, Canada, Europe** (para lab; mais barato).
   - Custom SSL certificate: pular agora, ou criar via ACM em `us-east-1` se já tem domínio.
8. Create.
9. Espere 5-10 minutos. Acesse `https://dxxxx.cloudfront.net/test.txt`.

### 🧪 Lab 4.4 — Domínio customizado + ACM

1. **Certificate Manager (em `us-east-1`!)** → Request certificate.
2. Domain: `cdn.streaming.example.com` (ou `*.streaming.example.com`).
3. Validation: DNS, hospedado em Route53 → "Create records in Route53" cria CNAMEs sozinho.
4. Espere status `Issued` (~5 min).
5. Volte na distribution → Edit → **Alternate domain names**: `cdn.streaming.example.com`. **Custom SSL certificate**: selecione o emitido.
6. **Route53** → Create record:
   - Name: `cdn`
   - Type: `A` Alias para CloudFront distribution.
7. Acesse `https://cdn.streaming.example.com/test.txt`.

### 🧪 Lab 4.5 — Signed cookies para conteúdo protegido

```bash
# 1. Gera par RSA
openssl genrsa -out private_key.pem 2048
openssl rsa -in private_key.pem -pubout -out public_key.pem

# 2. CloudFront → Key management → Public keys → Create
# Cole o conteúdo do public_key.pem.

# 3. Key groups → Create → adicione a public key.

# 4. Na distribution, behavior → "Restrict viewer access" → use Trusted key group.
```

Em código (Node.js exemplo abreviado):

```js
import { getSignedCookies } from "@aws-sdk/cloudfront-signer";

const policy = {
  Statement: [{
    Resource: "https://cdn.streaming.example.com/videos/abc/*",
    Condition: { DateLessThan: { "AWS:EpochTime": Math.floor(Date.now()/1000) + 3600 } }
  }]
};

const cookies = getSignedCookies({
  url: "https://cdn.streaming.example.com/videos/abc/*",
  keyPairId: "K2EXAMPLE",
  privateKey: process.env.CF_PRIVATE_KEY,
  policy: JSON.stringify(policy),
});
// res.cookie('CloudFront-Policy', cookies['CloudFront-Policy'], { ... });
```

### 🧪 Lab 4.6 — CORS no S3 (necessário para upload do navegador)

```json
{
  "CORSRules": [{
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["PUT", "POST", "GET"],
    "AllowedOrigins": ["https://app.streaming.example.com"],
    "ExposeHeaders": ["ETag"]
  }]
}
```

```bash
aws s3api put-bucket-cors --bucket $BUCKET --cors-configuration file://cors.json
```

### 🧪 Lab 4.7 — Invalidação de cache

```bash
# Invalida tudo (use raramente — primeiras 1000 paths/mês grátis, depois US$0.005/path)
aws cloudfront create-invalidation --distribution-id EABCD --paths "/*"

# Pattern melhor: versionar paths (ex: /v2/index.html), invalidar nunca.
```

---

## 4. Padrões importantes

### Versionamento de assets imutáveis

Para CSS/JS de frontend e HLS segments: **assets imutáveis** com hash no nome (`app.a1b2c3.js`, `seg-12345.ts`). Cache TTL longo (ano), nunca invalidar. Para `index.html` ou manifest mutável: TTL curto (segundos a minutos).

### Cache headers

Defina em S3 metadata ou em CloudFront response policy:

```
Cache-Control: public, max-age=31536000, immutable   # assets imutáveis
Cache-Control: public, max-age=10, s-maxage=60        # manifesto HLS
Cache-Control: no-cache                               # HTML index
```

### Sucessão de erros 4xx/5xx negativos

CloudFront cacheia 404/5xx por padrão (5 min). Em desenvolvimento isso confunde. Configure **error caching minimum TTL = 0** em behavior dev ou crie response que tem TTL diferente.

### Origin Shield

Ative em distribution com origin caro (S3 IA, ALB com lambda). Reduz origin requests em até 80%. Custo: US$ 0.0075/10k requests ao origin shield.

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Bucket público acidental | Vazamento, fatura monstro | Block Public Access ON; Access Analyzer |
| Multipart abandonado | GBs invisíveis cobrados | Lifecycle `AbortIncompleteMultipartUpload` |
| ACM no `sa-east-1` para CloudFront | "Cert não aparece" | Sempre `us-east-1` p/ CF |
| List buckets em hot path | $0.005/1000 LIST → caro em loop | Use prefix conhecido |
| Cache TTL = 0 em assets | Fatura CloudFront explode | TTL alto + versionamento |
| Recursão entre buckets | Loops gerando custo | Eventos com path filter |
| `s3:PutObject*` em policy | Drift de permissão | Action exata, Resource específico |
| Glacier sem entender retrieval cost | Restore de 1 TB pode custar US$ 100s | Leia preço de retrieval por classe |
| Cross-region replica esquecida | 2x storage + transfer | CRR só para casos com SLA |

**Custo real de exemplo (1 TB de vídeo, 10 TB de tráfego/mês na América do Norte):**

- S3 Standard storage: 1024 GB × US$ 0.023 = **US$ 23.55/mês**
- CloudFront egress (10 TB): ~US$ 0.085/GB nos primeiros 10 TB = **~US$ 850/mês** ← gigante
- CloudFront requests (200M): ~US$ 0.0075/10k = **US$ 150/mês**
- S3 GET requests do CF (cache hit 95%): pequeno

**Lição:** o que dói é egress. Otimize cache hit ratio.

---

## 6. Checklist de domínio

- [ ] Sei criar bucket S3 privado e configurar Block Public Access.
- [ ] Sei o que é storage class e quando usar Glacier vs Standard.
- [ ] Configurei lifecycle com transição + abort multipart.
- [ ] Habilitei versioning e entendo delete markers.
- [ ] Gerei presigned URL via CLI e via SDK.
- [ ] Criei distribution CloudFront com OAC + bucket privado.
- [ ] Tenho domínio próprio servindo via CloudFront com cert ACM.
- [ ] Sei configurar signed URLs/cookies para conteúdo restrito.
- [ ] Sei calcular custo aproximado de 1 TB armazenado + 10 TB egress.
- [ ] Configurei CORS no S3 para upload do navegador.

---

## 7. Recursos

**Oficiais:**
- [S3 User Guide](https://docs.aws.amazon.com/AmazonS3/latest/userguide/)
- [CloudFront Developer Guide](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/)
- [CloudFront pricing](https://aws.amazon.com/cloudfront/pricing/)
- [S3 best practices](https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html)

**Posts e vídeos:**
- "Deep dive on Amazon S3 storage classes" — re:Invent.
- "S3 performance best practices" — re:Invent.
- "Maximizing CloudFront cache hit ratio" — AWS blog.

**Ferramentas:**
- `s3-upload-stream` (Node) — multipart streaming.
- `rclone` — sync local ↔ S3 com paralelismo.
- `aws-sdk` cliente v3 (modular, recomendado para Node moderno).

---

➡️ Próximo: **Módulo 05 — Bancos de dados (RDS, DynamoDB)**.
