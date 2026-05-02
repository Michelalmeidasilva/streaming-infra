# Módulo 03 — IAM & Segurança

> **Meta do módulo:** dominar IAM (autenticação e autorização na AWS), entender o modelo de identidades, e configurar uma fundação de segurança decente para os módulos seguintes.

**Pré-requisitos:** módulo 01.

---

## 1. Conceitos

### 1.1 Os 4 elementos do IAM

| Elemento | O que é | Exemplo |
|----------|---------|---------|
| **User** | Identidade humana ou de aplicação legada | `admin-michel` |
| **Group** | Coleção de users | `developers`, `admins` |
| **Role** | Identidade temporária assumível | `lambda-encoder-role` |
| **Policy** | Documento JSON que descreve permissões | `AmazonS3ReadOnlyAccess` |

> 🧠 **Modelo mental:**
> - User = funcionário com crachá fixo.
> - Role = chave da sala temporária ("vou pegar agora, devolvo depois").
> - Policy = lista de "pode entrar aqui, não pode entrar ali".
> - Group = sigla do departamento (todos do `dev` herdam permissões do grupo).

### 1.2 Roles são a estrela do show

Em arquiteturas modernas você **mal usa users**. Quase tudo é role:

- **Lambda assume role** para acessar S3.
- **EC2 assume role** (instance profile) para acessar Secrets Manager.
- **Você** (humano) assume role via SSO em vez de logar com user fixo.
- **Pipeline GitHub Actions** assume role via OIDC (sem access key fixa).

> **Por quê?** Roles geram credenciais temporárias (15 minutos a 12h). Se vazar, expira sozinha. Access key de user é "para sempre" se ninguém girar.

### 1.3 Anatomia de uma policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowReadOurBucket",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::streaming-prod",
        "arn:aws:s3:::streaming-prod/*"
      ],
      "Condition": {
        "StringEquals": { "aws:RequestedRegion": "us-east-1" }
      }
    }
  ]
}
```

Elementos:

- **Effect** — `Allow` ou `Deny`. **Deny vence sempre.**
- **Action** — operações da API (use wildcard com cuidado: `s3:Get*`).
- **Resource** — ARNs específicos (evite `*` quando der).
- **Condition** — restrições adicionais: IP, MFA, tag, hora, região.
- **Principal** — só em **resource policies** (bucket policy, KMS), não em identity policies.

### 1.4 Identity policy vs Resource policy

| | Anexada a | Pergunta que responde |
|---|-----------|----------------------|
| Identity policy | User/Group/Role | "O que essa identidade pode fazer?" |
| Resource policy | Bucket S3, KMS key, SQS queue, Lambda, etc | "Quem pode acessar esse recurso?" |

Para chamada ser permitida: **uma das duas precisa permitir e nenhuma negar**. Em **mesma conta**: identity policy basta. **Cross-account**: precisa das duas.

### 1.5 Policy evaluation logic (a ordem que importa)

1. Permission boundary explícito? Se passar disso, segue.
2. Service Control Policy (SCP) da Organization? Se nega, FIM.
3. Resource-based policy? Allow explícito vence.
4. Identity-based policy? Allow.
5. Default: deny implícito.

Em qualquer momento, **um Deny explícito derruba tudo**.

### 1.6 IAM Identity Center (sucessor do AWS SSO)

Forma moderna de **usuários humanos** logarem na AWS:

- Você cria usuários no Identity Center (ou conecta a um IdP: Google, Azure AD, Okta).
- Cria **permission sets** (= conjunto de policies).
- Atribui usuário+permission set a contas AWS.
- Usuário acessa via **portal SSO** que gera credenciais temporárias.

> 💡 **Você deve migrar do user IAM admin para SSO** assim que possível. O user IAM com access key vira só backup.

### 1.7 Outras peças críticas de segurança

#### KMS (Key Management Service)

- Gerenciamento centralizado de chaves de criptografia.
- **AWS managed keys** (grátis, gerenciadas pela AWS) vs **customer managed keys** (US$ 1/mês cada, você controla rotação e policy).
- Quase todo serviço AWS usa KMS para criptografar (S3 SSE-KMS, RDS, EBS, Secrets Manager, etc).

#### Secrets Manager vs Parameter Store

| | Secrets Manager | SSM Parameter Store |
|---|----------------|--------------------|
| Custo | US$ 0.40/secret/mês + API | Grátis (Standard); US$ 0.05/param (Advanced) |
| Rotação automática | ✅ (Lambda integrada) | ❌ |
| Tipo | Secrets sensíveis (DB password) | Configs (URLs, feature flags) |
| Tamanho | até 64 KB | 4 KB (Standard), 8 KB (Advanced) |

Regra: **secret = Secrets Manager**, **config = Parameter Store**.

#### ACM (Certificate Manager)

- Certificados TLS **gratuitos** para domínios.
- Validação por DNS (Route53 valida sozinho) ou e-mail.
- Suporta wildcard.
- Para CloudFront, **emita o cert em `us-east-1`** independente da região do app — esquina de pegadinha.

#### WAF (Web Application Firewall)

- Regras em frente a CloudFront, ALB, API Gateway, AppSync.
- **Managed rule groups** (AWS, Marketplace) bloqueiam OWASP top 10, SQLi, bots.
- Custo: US$ 5/web ACL/mês + US$ 1/regra + US$ 0.60/1M reqs.

#### GuardDuty, Config, Security Hub

- **GuardDuty** — detecção de anomalias (chave AWS vazada, mineração de cripto, etc). Liga em 1 clique. ~US$ 4/conta/mês para tráfego pequeno.
- **AWS Config** — inventário e compliance (ex: "todos os buckets devem ter encryption"). US$ 0.003 por config item.
- **Security Hub** — dashboard que agrega achados do GuardDuty, Inspector, etc.

> Em produção real, ative os 3. Em laboratório, opcional (gera custo pequeno mas constante).

---

## 2. Por que isso importa no streaming

Em uma plataforma de streaming você lida com:

- **Conteúdo proprietário** (vídeo) — credenciais para acesso ao S3 não podem vazar.
- **Dados de usuários** (e-mails, métodos de pagamento) — LGPD/GDPR.
- **Chaves DRM** — comprometimento = pirataria em massa.
- **Pipeline de upload** — usuário faz upload direto para S3 com presigned URL gerada pelo backend → o IAM da Lambda do backend não pode ser amplo demais ("Allow s3:PutObject só no prefixo `uploads/${user_id}/`").
- **Roles cross-service** — MediaConvert precisa de role para ler do S3, escrever no S3, e publicar no SNS.

Cada serviço que orquestra outro precisa de uma role bem desenhada. Se você acertar IAM, metade da segurança da plataforma já está de pé.

---

## 3. Laboratório prático

### 🧪 Lab 3.1 — Criar role para uma Lambda

```bash
# 1. Trust policy: quem pode assumir a role
cat > trust-lambda.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

# 2. Cria role
aws iam create-role --role-name lambda-encoder-role \
  --assume-role-policy-document file://trust-lambda.json

# 3. Anexa managed policy básica de logs
aws iam attach-role-policy --role-name lambda-encoder-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 4. Adiciona inline policy específica (least-privilege)
cat > policy-encoder.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": "arn:aws:s3:::streaming-uploads/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": "arn:aws:s3:::streaming-output/*"
    },
    {
      "Effect": "Allow",
      "Action": ["mediaconvert:CreateJob"],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy --role-name lambda-encoder-role \
  --policy-name encoder-permissions \
  --policy-document file://policy-encoder.json
```

Boas práticas demonstradas:

- Trust policy específica (só Lambda assume).
- Managed policy para logs (não reinventa a roda).
- Inline policy **escopo de bucket** (não wildcard `s3:*`).

### 🧪 Lab 3.2 — Configurar IAM Identity Center

1. **IAM Identity Center → Enable**.
2. **Settings → Identity source** → mantenha "Identity Center directory" para começar.
3. **Users → Add user** — crie o seu usuário humano (`michel`).
4. **Permission sets → Create**:
   - `AdministratorAccess` (PowerUser pra começar; refine depois).
   - Session duration: 4h.
5. **AWS accounts → selecione a conta → Assign users** → atribua `michel` com o permission set.
6. Acesse a **AWS access portal URL** (mostrada no dashboard).
7. Login com MFA → escolha conta → "Management console" abre logado.

Para CLI:

```bash
$ aws configure sso
SSO start URL: https://d-xxxxx.awsapps.com/start
SSO region: us-east-1
... (segue prompts)

# Use o profile criado
$ aws sts get-caller-identity --profile streaming-sso
```

A partir daqui você usa `--profile streaming-sso` para tudo. **Pode até deletar a access key longeva do user IAM admin.**

### 🧪 Lab 3.3 — Secret no Secrets Manager

```bash
# Cria secret
aws secretsmanager create-secret \
  --name streaming/db/master-password \
  --secret-string '{"username":"streamadmin","password":"S3nh@F0rt3!Ex@mple"}' \
  --tags Key=Project,Value=streaming-learning

# Lê secret
aws secretsmanager get-secret-value \
  --secret-id streaming/db/master-password \
  --query SecretString --output text | jq
```

> 💡 **Padrão:** o nome do secret usa **path**: `streaming/<env>/<resource>/<key>`. Facilita IAM com wildcard scope.

### 🧪 Lab 3.4 — Cofre de configs no Parameter Store

```bash
# String simples
aws ssm put-parameter --name "/streaming/api/base-url" \
  --value "https://api.streaming.example.com" --type String

# String segura (criptografada com KMS)
aws ssm put-parameter --name "/streaming/api/jwt-secret" \
  --value "super-secret-jwt-signing-key" --type SecureString

# Listar e ler
aws ssm get-parameters-by-path --path "/streaming/" --recursive --with-decryption
```

### 🧪 Lab 3.5 — KMS customer managed key

```bash
# Cria key
KEY_ID=$(aws kms create-key --description "Streaming videos at rest" \
  --tags TagKey=Project,TagValue=streaming-learning \
  --query 'KeyMetadata.KeyId' --output text)

# Alias amigável
aws kms create-alias --alias-name alias/streaming-videos --target-key-id $KEY_ID

# Habilita rotação automática anual
aws kms enable-key-rotation --key-id $KEY_ID
```

### 🧪 Lab 3.6 — Auditando permissões

**IAM Access Analyzer** (grátis):

1. **IAM → Access Analyzer → Create analyzer** (zone of trust = Account).
2. Lista buckets S3, roles, KMS keys com **acesso externo** (cross-account ou público).
3. Use para encontrar buckets acidentalmente públicos.

**Last accessed information**:

```bash
# Quais services o user/role usou recentemente?
aws iam generate-service-last-accessed-details --arn arn:aws:iam::123:role/lambda-encoder-role
# (espera ~minuto)
aws iam get-service-last-accessed-details --job-id <id>
```

Use para **encolher policies super amplas**: "essa role tem `*` mas só usou S3 e Lambda nos últimos 90 dias → reduzir."

---

## 4. Boas práticas de IAM

1. **Least privilege** — comece com nada, adicione conforme erro `AccessDenied`.
2. **Roles, não users** — para apps, sempre roles. Users só para humanos (e idealmente via SSO).
3. **Sem access keys longevas em código.** Use `aws-vault`, SSO, OIDC para CI.
4. **MFA em todo user humano**, **MFA condicional para ações sensíveis** (`Condition: aws:MultiFactorAuthPresent: true`).
5. **Permission boundaries** para developers: "você pode criar roles, mas só com policies dentro deste boundary".
6. **SCPs em Organizations** — `Deny` global a ações catastróficas (ex: `kms:DeleteKey`, `s3:DeleteBucket` em buckets de produção).
7. **Rotação de secrets** — Secrets Manager + Lambda rotation pelo menos a cada 90 dias.
8. **Audit log via CloudTrail** — todas as chamadas de API ficam gravadas.
9. **Avoid trust `*`** — trust policy `Principal: "*"` é raro e sempre exige `Condition`.

### Anti-padrões

- ❌ User com access key em `~/.aws/credentials` no notebook.
- ❌ Policy `Action: "*", Resource: "*"` em qualquer role de aplicação.
- ❌ Bucket S3 com policy `"Principal": "*"` sem condição.
- ❌ Secret de produção como variável de ambiente em texto plano em GitHub.
- ❌ Compartilhar role entre dev e prod ("para simplificar").

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Access key vazada no GitHub | Conta minerando cripto em horas | git-secrets, scanners, OIDC |
| Trust policy super-aberta | Cross-account hijack | Sempre usar `aws:SourceArn` ou external ID |
| KMS key deletada | Dados criptografados ficam ilegíveis | Schedule deletion (mín. 7 dias), key policy lock |
| `iam:PassRole` mal escopado | Privilege escalation | `Condition` com `iam:PassedToService` |
| Permission boundary esquecido | Developer cria role com `*` | Boundary obrigatório via SCP |
| Secret no env var de Lambda | Logs / Cloudtrail vazam | Secrets Manager + cache de SDK |
| Wildcard em production policies | Drift de segurança | Access Analyzer + revisão trimestral |

**Custos típicos:** IAM em si é grátis. KMS customer managed = US$ 1/key/mês + US$ 0.03/10k API calls. Secrets Manager = US$ 0.40/secret/mês. WAF = US$ 5/web ACL.

---

## 6. Checklist de domínio

- [ ] Sei a diferença entre user, group, role e policy.
- [ ] Sei explicar por que role > user para aplicações.
- [ ] Escrevi à mão uma policy IAM com Action, Resource e Condition.
- [ ] Configurei IAM Identity Center e estou logando via SSO no console e CLI.
- [ ] Criei role com trust policy específica para um serviço.
- [ ] Tenho pelo menos um secret no Secrets Manager e configs no Parameter Store.
- [ ] Tenho uma KMS key customer managed criada (mesmo que ainda não use).
- [ ] Sei o que faz IAM Access Analyzer.
- [ ] Apaguei (ou planejei apagar) access keys longevas do user admin.

---

## 7. Recursos

**Oficiais:**
- [IAM User Guide](https://docs.aws.amazon.com/IAM/latest/UserGuide/)
- [Policy reference](https://docs.aws.amazon.com/service-authorization/latest/reference/) — todas as Actions/Resources/Conditions por serviço.
- [IAM Identity Center docs](https://docs.aws.amazon.com/singlesignon/)

**Vídeos:**
- AWS re:Inforce — qualquer talk sobre "IAM permissions deep dive".
- Becky Weiss — "Building delicious IAM" (re:Invent IAM masterclass).

**Ferramentas:**
- `iamlive` — gera política mínima a partir de chamadas reais.
- `parliament` (Salesforce) — linter de policies.
- `cloudsplaining` (Salesforce) — audita policies amplas.

---

➡️ Próximo: **Módulo 04 — Storage & CDN (S3 + CloudFront)**.
