# AWS IaC — Runbook do Operador

> Como subir o ambiente AWS (us-east-2) dos serviços VOD. O código foi **autorado e
> validado** (`terraform validate`/`fmt` ✅); este runbook cobre os passos que **tocam a
> AWS** e que você executa com suas credenciais. Spec e planos completos em
> `docs/design-docs/plans/2026-06-03-aws-iac-*.md` e
> `docs/design-docs/specs/2026-06-03-aws-iac-terraform-ansible-design.md`.

---

## O que já está pronto (autorado nesta sessão)

Branch de origem: `feat/aws-iac` (merge em `master`). Terraform binário: `infra/bin/terraform` (1.10.5).

**Terraform `infra/aws/`** — `validate` e `fmt -check` limpos:

| Módulo | Papel |
|---|---|
| `bootstrap/` | cria o bucket de state (state local; rodar 1×) |
| `backend.tf` | backend S3 + lock nativo (`use_lockfile`) |
| `network/` | VPC mínima (2 subnets públicas, SG do Batch, sem NAT) |
| `ssm-secrets/` | SecureString: MONGODB_URI, RABBITMQ_URL, REDIS_URL, S3 creds |
| `storage-s3/` | bucket (adotado via import) + lifecycle + EventBridge notification |
| `iam-s3/` | IAM user least-privilege no bucket |
| `ecr/` | 3 repositórios (vod-ingest/distribution/transcode) |
| `ingest-lambda/` | Lambda container + Function URL (adota a função existente) |
| `distribution-lambda/` | Lambda container + Function URL + CloudFront PriceClass_100 |
| `transcode-batch/` | Batch Fargate Spot + job queue + job def + SLR |
| `events/` | EventBridge: S3→Batch (SubmitJob) e S3→ingest (API Destination) |
| `web-client-cdn/` | S3 site + CloudFront + OAC |
| `scripts/aws-audit.sh` | auditoria read-only do bucket + ingest existentes |

**Ansible `infra/ansible/`** — YAML válido (syntax-check completo pendente: `ansible` não estava instalado na máquina de autoria):
`build-push.yml` · `deploy.yml` · `configure-broker.yml` · `web-client.yml` · `smoke.yml` + skeleton.

**Mudança de serviço:** `streaming-distribution/Dockerfile` ganhou o `aws-lambda-web-adapter` (commit no git do próprio serviço).

**Correções da revisão final já aplicadas no código:**
- `storage-s3`: versioning `Suspended` → `Disabled` (evita `InvalidBucketState` no import de bucket nunca versionado).
- `transcode-batch`: service-linked role `AWSServiceRoleForBatch` criado (flag `create_batch_service_linked_role`, default true) + `depends_on`.
- `ecr`: `force_delete = false` (não apagar imagens no destroy).

---

## Pré-requisitos

```bash
aws sts get-caller-identity      # perfil com admin na conta alvo
jq --version
docker version                   # daemon rodando
node --version                   # 20.x p/ build do web-client
ansible --version                # 2.16+
```

---

## Fase 1 — Foundation (Plano 1)

```bash
# 1. Auditar o que já existe (read-only). Anote o nome real do bucket e da função.
REGION=us-east-2 bash infra/aws/scripts/aws-audit.sh
BUCKET=<bucket-real> INGEST_FN=<ingest-real> REGION=us-east-2 \
  bash infra/aws/scripts/aws-audit.sh | tee /tmp/aws-audit-report.txt

# 2. Criar o bucket de state (state local)
infra/bin/terraform -chdir=infra/aws/bootstrap init
infra/bin/terraform -chdir=infra/aws/bootstrap apply

# 3. Preencher variáveis e segredos (arquivo git-ignored)
cp infra/aws/terraform.tfvars.example infra/aws/terraform.tfvars
#   -> editar: storage_bucket_name = "<bucket-real>"
#   -> editar: mongodb_uri / rabbitmq_url / redis_url

# 4. Inicializar o backend remoto
infra/bin/terraform -chdir=infra/aws init

# 5. Conferir no /tmp/aws-audit-report.txt:
#    - Se o SLR AWSServiceRoleForBatch já existe na conta:
#        adicionar  create_batch_service_linked_role = false  no terraform.tfvars
#        (ou em main.tf no module.transcode_batch)
#    - Estado real de versioning do bucket (deve ser off → "Disabled" já cobre)

# 6. Adotar o bucket existente
infra/bin/terraform -chdir=infra/aws import \
  'module.storage_s3.aws_s3_bucket.this' "<bucket-real>"

# 7. Revisar o plan — NÃO deve haver destroy do bucket
infra/bin/terraform -chdir=infra/aws plan
```

## Fase 2 — Compute (Plano 2)

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=us-east-2
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"

# 8. Criar os repositórios ECR primeiro
infra/bin/terraform -chdir=infra/aws apply -target=module.ecr

# 9. Build + push das 3 imagens (amd64)
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "$REGISTRY"
for svc in ingest distribution transcode; do
  docker build --platform linux/amd64 -t "$REGISTRY/vod-$svc:latest" "streaming-$svc"
  docker push "$REGISTRY/vod-$svc:latest"
done

# 10. Adotar o ingest existente — ver PackageType no relatório:
#     - PackageType=Image  -> importar:
infra/bin/terraform -chdir=infra/aws import \
  'module.ingest_lambda.aws_lambda_function.this' "<ingest-real>"
#     - PackageType=Zip    -> PARE: o apply recria a função e a Function URL muda
#       (atualizar a URL do ingest na Vercel). Decidir antes de seguir.

# 11. Apply completo — revisar o plan (imagens já no ECR no passo 9)
infra/bin/terraform -chdir=infra/aws apply
infra/bin/terraform -chdir=infra/aws output   # anotar ingest_function_url, *_cdn_domain
```

## Fase 3 — Deploy/config via Ansible (Plano 3)

```bash
cd infra/ansible
ansible-galaxy collection install -r requirements.yml -p ./.galaxy
ansible -i inventory/hosts.ini local -m ping            # pong
ansible-playbook --syntax-check build-push.yml deploy.yml web-client.yml smoke.yml

# Topologia do broker (CloudAMQP) — criar o vault com as credenciais
ansible-vault create vault.yml
#   cloudamqp_host: SUBDOMINIO.cloudamqp.com
#   cloudamqp_user: ...   cloudamqp_pass: ...   cloudamqp_vhost: ...
ansible-playbook configure-broker.yml --ask-vault-pass

# Publicar o web-client e rodar smoke
ansible-playbook web-client.yml
ansible-playbook smoke.yml
cd -
```

> Os playbooks `build-push.yml`/`deploy.yml` automatizam os passos 9 e a atualização das
> Lambdas — em deploys subsequentes use-os no lugar dos comandos `docker` manuais.

---

## Pendências fora do IaC (precisam de código nos serviços)

### P1 — `streaming-transcode`: `cmd/transcode-local` precisa rodar como job Batch
**Por quê:** o trigger é `S3 ObjectCreated(raw/) → EventBridge → Batch SubmitJob`, e o job
roda `transcode-local Ref::s3_key`. Hoje `transcode-local` é um utilitário de transcode
local; ele precisa virar o entrypoint do job.

**Implementação esperada:**
1. **Argumento:** ler `argv[1]` = a key do S3, no formato `raw/{video_id}/original.<ext>`.
   Extrair `video_id` do path.
2. **Config (env do Batch):** `STORAGE_BUCKET`, `AWS_REGION`, e as secrets injetadas pelo
   Batch a partir do SSM — `MONGODB_URI`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`
   (nomes definidos em `transcode-batch/main.tf` → `container_properties.secrets`).
3. **Download:** baixar `s3://$STORAGE_BUCKET/<argv[1]>` para `TRANSCODE_WORKDIR` (`/tmp/transcode`).
4. **Pipeline:** rodar a escada de bitrate **completa** (360/480/720/**1080**, sem teto —
   decisão D11) com **GOPs alinhados** (`-g 60 -keyint_min 60 -sc_threshold 0`) + shaka-packager
   → segmentos HLS/DASH + manifests.
5. **Upload:** enviar para `s3://$STORAGE_BUCKET/transcoded/{video_id}/...` e
   `manifests/{video_id}.m3u8` / `.mpd`.
6. **MongoDB (crítico — distribution é read-only e não consome fila):**
   - `transcoding_jobs`: `updateOne({video_id}, {$set:{status:"completed", completed_at}})`.
   - `manifests`: `insert/update {video_id, hls_url, dash_url}` apontando para as keys/paths
     em `transcoded/`/`manifests/` que o `streaming-distribution` transforma em URL
     presigned/CDN no GET. Conferir o schema que o distribution lê (coleção `manifests`).
7. **Exit code:** `0` em sucesso (Batch marca SUCCEEDED), ≠0 em falha (Batch marca FAILED →
   reprocessável). Logs vão para o CloudWatch group `/vod/prod/transcode`.

> O `cmd/worker` (consumer de RabbitMQ) deixa de ser o caminho de produção do transcode,
> mas pode permanecer para dev local. Atualizar `SPEC.md`/`CHANGELOG.md`/`docs/` do serviço.

### P2 — `streaming-platform-upload` (Vercel): URL do ingest
Se a função ingest for **recriada** (caso `PackageType=Zip`, Fase 2 passo 10), a Function URL
muda. Atualizar a env do upload na Vercel que aponta para o ingest. Se for `Image` (import),
a URL é preservada.

---

## Caveats da revisão final (aceitos por design enxuto — endereçar depois)

- **Tags `:latest`** em Lambda/Batch: re-deploy não é idempotente nem tem rollback simples.
  Recomendado migrar para **digest imutável** (passar o digest como variável; `ecr` já permite
  trocar para `image_tag_mutability=IMMUTABLE`).
- **Sem DLQ** no evento `S3 → ingest` (API Destination): se o ingest estiver fora do ar, o
  evento é descartado após os retries do EventBridge. Considerar `dead_letter_config`.
- **Function URLs públicas** (`authorization_type=NONE`): clientes podem furar o CloudFront e
  bater direto na Function URL do distribution. O ingest valida (deve validar) o header
  estático `x-eventbridge: s3-notification` enviado pela API Destination — **confirmar no app**.
- **Creds do distribution como env var** (não SSM em runtime): visíveis no console a quem tem
  `lambda:GetFunctionConfiguration`. Intencional (D do spec), mas é um trade-off conhecido.

---

## Próximo passo documentado (não implementado)

**CI/CD via GitHub Actions + OIDC:** assumir uma IAM Role federada (sem chave AWS no repo),
rodar `terraform plan` no PR e `apply` no merge; encadear os playbooks Ansible. Bootstrap:
criar o OIDC provider + Role. Ver `infra/ansible/README.md` e o spec.
