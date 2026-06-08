# Deploy AWS — Passo a Passo Detalhado

> Guia operacional granular para **provisionar do zero** a infra VOD em `us-east-2`.
> Companheiro do `RUNBOOK.md` (visão por fases) e do `docs/architecture.md` (diagrama).
> Todos os comandos assumem que você está na **raiz do monorepo** (`microsservices/`).
> O binário do Terraform é `infra/bin/terraform` (1.10.5) — use sempre ele.

**Convenções deste guia**
- `TF` = `infra/bin/terraform`
- 🟢 = passo que **não** toca a AWS (seguro). 🔴 = passo que **cria/altera** recursos.
- Cada passo tem **Comando → Saída esperada → ✅ Checkpoint**. Não avance sem o checkpoint.

---

## Fase 0 — Pré-requisitos e auditoria (🟢 read-only)

### 0.1 — Ferramentas locais
```bash
infra/bin/terraform version      # -> Terraform v1.10.5
aws --version                    # -> aws-cli/2.x
docker version                   # daemon precisa estar RODANDO
jq --version                     # -> jq-1.x
node --version                   # -> v20.x (build do web-client)
ansible --version                # -> 2.16+ (core); se faltar: pipx install ansible
```
✅ **Checkpoint:** todos respondem versão, sem "command not found".

### 0.2 — Credenciais AWS (perfil admin na conta alvo)
```bash
aws sts get-caller-identity --output table
```
Saída esperada: tabela com `Account`, `Arn`, `UserId`. O `Arn` deve ser de um
principal com permissão de admin (vai criar IAM, Lambda, Batch, CloudFront, etc).
✅ **Checkpoint:** a conta retornada é a **conta de destino** (anote o `Account` id).

### 0.3 — Auditoria do que já existe (descobre bucket e função ingest)
```bash
# Passo 1: descoberta por heurística (sem BUCKET/INGEST_FN)
REGION=us-east-2 bash infra/aws/scripts/aws-audit.sh

# Passo 2: re-rode com os nomes reais descobertos, salvando o relatório
BUCKET=<bucket-real> INGEST_FN=<ingest-real> REGION=us-east-2 \
  bash infra/aws/scripts/aws-audit.sh | tee /tmp/aws-audit-report.txt
```
✅ **Checkpoints (anote do relatório):**
- [ ] **Nome real do bucket** S3 existente.
- [ ] **Versioning do bucket**: deve estar vazio/`Disabled` (o módulo usa `Disabled`).
      Se estiver `Enabled`/`Suspended`, veja o caveat em §Apêndice A.
- [ ] **`PackageType` da Lambda ingest**: `Image` ou `Zip` (decide a Fase 2.5).
- [ ] **SLR do Batch** existe? Verifique: `aws iam get-role --role-name AWSServiceRoleForBatch`.
      Se **existir**, você vai setar `create_batch_service_linked_role = false`.

---

## Fase 1 — Foundation (state remoto + bucket + secrets) 🔴

### 1.1 — Criar o bucket de state do Terraform (roda 1× por conta)
```bash
TF=infra/bin/terraform
$TF -chdir=infra/aws/bootstrap init
$TF -chdir=infra/aws/bootstrap apply        # confirme com 'yes'
$TF -chdir=infra/aws/bootstrap output        # -> state_bucket_name = "vod-tfstate-prod-use2"
```
> O nome `vod-tfstate-prod-use2` é o default em `bootstrap/variables.tf` e **tem que
> bater** com `backend.tf`. Se já existir (erro `BucketAlreadyOwnedByYou`), o backend
> já está pronto — pode seguir.

✅ **Checkpoint:** `aws s3 ls | grep vod-tfstate-prod-use2` retorna o bucket.

### 1.2 — Preencher variáveis e segredos (arquivo git-ignored)
O `terraform.tfvars` já existe mas tem **placeholders**. Edite:
```bash
$EDITOR infra/aws/terraform.tfvars
```
Preencha:
```hcl
storage_bucket_name = "<bucket-real-da-auditoria>"   # OBRIGATÓRIO — hoje está <PREENCHER-*>
mongodb_uri  = "mongodb+srv://user:pass@cluster.mongodb.net/streaming"
rabbitmq_url = "amqps://user:pass@host.cloudamqp.com/vhost"
redis_url    = "rediss://user:pass@host:6379"
```
Se o **SLR do Batch já existe** (Fase 0.3), adicione também:
```hcl
# (passado ao módulo via main.tf, ver §Apêndice B se precisar)
```
✅ **Checkpoint:** `grep PREENCHER infra/aws/terraform.tfvars` **não retorna nada**.

### 1.3 — Inicializar o backend remoto (🟢 não cria infra, só conecta no state)
```bash
$TF -chdir=infra/aws init
```
Saída esperada: `Successfully configured the backend "s3"! ... Terraform has been successfully initialized!`
✅ **Checkpoint:** existe `infra/aws/.terraform/terraform.tfstate` apontando para `backend": "s3"`.

### 1.4 — Adotar o bucket S3 existente (import — não recria) 🔴(metadado)
```bash
$TF -chdir=infra/aws import \
  'module.storage_s3.aws_s3_bucket.this' "<bucket-real>"
```
✅ **Checkpoint:** `Import successful!`

### 1.5 — Revisar o plan da foundation (🟢 só leitura)
```bash
$TF -chdir=infra/aws plan
```
✅ **Checkpoints (CRÍTICO — não aplique se falhar):**
- [ ] **NENHUM `destroy` do bucket** (`aws_s3_bucket.this`). Só `~ update`/`+ create` de
      configs (CORS, lifecycle, encryption, notification).
- [ ] Recursos a criar: ECR(3), SSM(5), IAM user+policy, VPC/subnets/SG, IAM roles das Lambdas.

---

## Fase 2 — Compute (ECR → imagens → Lambdas/Batch/CDN) 🔴

### 2.1 — Criar SÓ os repositórios ECR primeiro
```bash
$TF -chdir=infra/aws apply -target=module.ecr      # confirme 'yes'
```
✅ **Checkpoint:** `aws ecr describe-repositories --region us-east-2 --query 'repositories[].repositoryName'`
retorna `vod-ingest`, `vod-distribution`, `vod-transcode`.

### 2.2 — Build + push das 3 imagens (amd64) — manual OU via Ansible

**Opção A — manual (transparente):**
```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-2
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

aws ecr get-login-password --region $REGION \
  | docker login --username AWS --password-stdin "$REGISTRY"

for svc in ingest distribution transcode; do
  docker build --platform linux/amd64 -t "$REGISTRY/vod-$svc:latest" "streaming-$svc"
  docker push "$REGISTRY/vod-$svc:latest"
done
```
**Opção B — via Ansible (idempotente, usado em re-deploys):**
```bash
cd infra/ansible
ansible-galaxy collection install -r requirements.yml -p ./.galaxy
ansible-playbook build-push.yml
cd -
```
> Os 3 Dockerfiles já incluem o `aws-lambda-adapter:0.9.1` (Function URL serve o HTTP
> server Go via `AWS_LWA_PORT`). O transcode roda `transcode-local Ref::s3_key` no Batch.

✅ **Checkpoint:** cada repo tem a tag `latest`:
```bash
aws ecr describe-images --region us-east-2 --repository-name vod-ingest \
  --query 'imageDetails[].imageTags' --output text   # -> latest
```
**⚠️ Não pule:** o `apply` da Lambda referencia `:latest`; sem a imagem no ECR ele **falha**.

### 2.3 — Decisão de adoção do ingest (depende do `PackageType` da Fase 0.3)
- **`PackageType = Image`** → importe (preserva a Function URL existente):
  ```bash
  $TF -chdir=infra/aws import \
    'module.ingest_lambda.aws_lambda_function.this' "<ingest-real>"
  ```
- **`PackageType = Zip`** → **PARE e decida**: o apply vai **recriar** a função e a
  **Function URL muda**. Consequência: atualizar a env do ingest na **Vercel**
  (`streaming-platform-upload`) após a Fase 2.4. Não há import limpo Zip→Image.

✅ **Checkpoint:** se Image, `Import successful!`. Se Zip, você **registrou** que vai
atualizar a Vercel no fim.

### 2.4 — Apply completo da stack 🔴
```bash
$TF -chdir=infra/aws plan      # revise: imagens já no ECR, sem destroy do bucket
$TF -chdir=infra/aws apply     # confirme 'yes' — leva alguns min (CloudFront ~ lento)
```
✅ **Checkpoint:** `Apply complete!` e colete os outputs:
```bash
$TF -chdir=infra/aws output
```
Anote:
- [ ] `ingest_function_url`            (ex.: `https://xxx.lambda-url.us-east-2.on.aws/`)
- [ ] `distribution_cdn_domain`        (ex.: `dxxxx.cloudfront.net`)
- [ ] `web_client_cdn_domain`
- [ ] `bucket_name`, `vpc_id`, `observability_dashboard`

### 2.5 — (Só se ingest era `Zip`) atualizar a Vercel
Atualize a env que aponta para o ingest no projeto `streaming-platform-upload` na Vercel
para o novo `ingest_function_url`, e re-deploy do front.
✅ **Checkpoint:** upload de teste no front chega no ingest (ver Fase 4 smoke).

---

## Fase 3 — Configuração & publicação (Ansible) 🔴

```bash
cd infra/ansible
ansible-galaxy collection install -r requirements.yml -p ./.galaxy
ansible -i inventory/hosts.ini local -m ping            # -> "ping": "pong"
ansible-playbook --syntax-check build-push.yml deploy.yml web-client.yml smoke.yml
```
✅ **Checkpoint:** `ping/pong` e syntax-check sem erro.

### 3.1 — Topologia do broker (CloudAMQP) — exchange + filas + bindings
```bash
ansible-vault create vault.yml      # cria o cofre criptografado
```
Conteúdo do `vault.yml`:
```yaml
cloudamqp_host: <SUBDOMINIO>.cloudamqp.com    # sem o amqps://
cloudamqp_user: <user>
cloudamqp_pass: <pass>
cloudamqp_vhost: <vhost>
```
```bash
ansible-playbook configure-broker.yml --ask-vault-pass
```
> Declara o exchange topic `video_events` + filas `transcoding_queue`
> (`video.upload.*`), `distribution_queue` (`video.transcode.completed`),
> `telemetry_queue` (`video.*.*`) com bindings.

✅ **Checkpoint:** no painel do CloudAMQP as 3 filas e o exchange aparecem (durable).

### 3.2 — Publicar o web-client (build → S3 → invalidação CloudFront)
```bash
ansible-playbook web-client.yml
```
> Lê os outputs do Terraform, faz `npm install && npm run build` do
> `streaming-web-client` com `PUBLIC_DISTRIBUTION_URL` **baked em build time**
> (rebuild obrigatório se a URL mudar), sincroniza no S3 e invalida o CDN.

✅ **Checkpoint:** `https://<web_client_cdn_domain>` carrega o app.

---

## Fase 4 — Smoke test ponta-a-ponta 🟢

```bash
cd infra/ansible
ansible-playbook smoke.yml
cd -
```
Valida: `ingest /health`, `distribution /health` (via CDN), `web-client root`, e que a
**Batch job queue está `VALID`**.

### 4.1 — Teste real do pipeline (manual)
1. Faça upload de um vídeo curto pelo front (`streaming-platform-upload`).
2. O objeto cai em `s3://<bucket>/raw/<video_id>/...`.
3. EventBridge dispara **em paralelo**: (a) Batch `SubmitJob` (transcode) e
   (b) API Destination → ingest webhook (`/api/v1/webhooks/storage/s3`).
4. Acompanhe o job:
   ```bash
   aws batch list-jobs --region us-east-2 --job-queue vod-prod-transcode \
     --query 'jobSummaryList[].[jobName,status]' --output table
   ```
5. Logs do transcode: CloudWatch group `/vod/prod/transcode`.
6. Saída transcodificada em `s3://<bucket>/transcoded/<video_id>/...`.
7. O `distribution` (via CloudFront) serve o manifest do vídeo.

✅ **Checkpoint final:** vídeo aparece no web-client e dá play (HLS/DASH).

---

## Apêndice A — Versioning do bucket
O módulo `storage-s3` força `status = "Disabled"` (válido para bucket que **nunca** teve
versioning). Se a auditoria mostrou `Enabled`/`Suspended`, mude `modules/storage-s3/main.tf`
para `Suspended` **antes** do plan, senão dá `InvalidBucketState`.

## Apêndice B — Service-linked role do Batch
Se `AWSServiceRoleForBatch` **já existe** na conta (Fase 0.3), evite o erro de "role já
existe" passando ao módulo `transcode_batch` em `aws/main.tf`:
```hcl
module "transcode_batch" {
  # ...
  create_batch_service_linked_role = false
}
```

## Apêndice C — Re-deploy (deploys subsequentes)
Não recriar tudo. Só nova imagem + refresh das Lambdas:
```bash
cd infra/ansible
ansible-playbook build-push.yml deploy.yml smoke.yml
```
> `deploy.yml` faz `update-function-code` nas 2 Lambdas e espera estabilizar.
> Caveat: tags `:latest` não têm rollback imutável (ver `RUNBOOK.md`).

## Apêndice D — Rollback / destroy
- **Reverter código de Lambda:** re-push da imagem anterior + `deploy.yml`.
- **Destruir a stack de compute** (preserva o bucket de dados, que foi importado e o
  ECR tem `force_delete=false`):
  ```bash
  infra/bin/terraform -chdir=infra/aws destroy
  ```
  ⚠️ Revise o plan de destroy: o bucket de **dados** foi adotado via import — confirme
  que ele **não** está marcado para deleção se você quiser preservá-lo (remova do state
  com `terraform state rm 'module.storage_s3.aws_s3_bucket.this'` antes, se necessário).

---

## Checklist resumido (copiar para o ticket)
- [ ] 0.1 ferramentas · 0.2 conta certa · 0.3 auditoria salva (bucket, PackageType, SLR)
- [ ] 1.1 bootstrap state · 1.2 tfvars sem PREENCHER · 1.3 init · 1.4 import bucket · 1.5 plan sem destroy
- [ ] 2.1 ECR · 2.2 imagens no ECR (3× latest) · 2.3 decisão ingest Image/Zip · 2.4 apply + outputs
- [ ] 3.1 broker CloudAMQP · 3.2 web-client publicado
- [ ] 4 smoke verde · 4.1 upload E2E dá play
- [ ] (se Zip) Vercel atualizada com a nova ingest_function_url

### Cost guard
Após o apply, confirme os 2 e-mails de subscription do SNS (`vod-prod-cost-alerts`
e `vod-prod-cost-killswitch`). Os budgets ($40/mês, $3/dia) só notificam após
confirmação. Recuperação após disparo do kill-switch:
`DIST_IDS="<id-distribution> <id-web-client>" bash aws/scripts/cost-guard-rearm.sh`.
