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

### P1 — `streaming-transcode`: `cmd/transcode-local` como job Batch — ✅ IMPLEMENTADO (2026-06-07)

**Por quê:** o trigger é `S3 ObjectCreated(raw/) → EventBridge → Batch SubmitJob`, e o job
roda `transcode-local Ref::s3_key`. `transcode-local` virou o entrypoint do job (mantendo o
modo local-file por flags para dev).

**Como ficou (ver `streaming-transcode/docs/batch-entrypoint.md`):**
1. **Argumento:** `argv[1]` = a key do S3 no formato `raw/{video_id}/{object}` (o nome do
   objeto é o filename normalizado do upload, não necessariamente `original.<ext>`).
   `extractVideoID` deriva o `video_id`.
2. **Config (env do Batch):** `STORAGE_PROVIDER=s3`, `STORAGE_BUCKET`, `AWS_REGION`,
   `EVENT_GATEWAY_URL` (Function URL do ingest + `/api/v1`), e as secrets de S3 do SSM
   mapeadas para `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (params SSM continuam `S3_*`).
   **Sem `MONGODB_URI`** — o job não fala Mongo.
3. **Download → pipeline → upload:** reusa `worker.Processor.Process` inteiro — escada
   **completa** (360/480/720/**1080**, sem teto, D11), GOPs alinhados + shaka-packager,
   upload de HLS/DASH para `transcoded/{video_id}/...`.
4. **Persistência via Event Gateway (não Mongo direto):** o `Processor` chama o ingest
   (`PATCH /api/v1/upload-state/videos/:id` + eventos em `POST /api/v1/events`). O ingest é
   o **escritor único** da coleção `videos` que o `streaming-distribution` lê. **Não existe
   coleção `manifests`** — a suposição original deste runbook estava incorreta.
5. **Exit code:** `0` SUCCEEDED, ≠0 FAILED (reprocessável). Logs no CloudWatch group do Batch.

**Mudanças de infra aplicadas (ver `infra/CHANGELOG.md`):** `transcode-batch` dropou o secret
`MONGODB_URI`, ganhou `EVENT_GATEWAY_URL` (var `event_gateway_url`, wired no root para
`${module.ingest_lambda.function_url}api/v1`), e corrigiu o nome dos env de credencial S3.

> Caveats v1: modo Batch **não** anuncia legendas sidecar e **rejeita `.yuv`** (sem geometria
> no evento S3). O `cmd/worker` (RabbitMQ) permanece só para dev local.

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

## Benchmark

### Habilitando o harness de benchmark

Para ativar a frota de benchmark, passe `enable_transcode_benchmark_harness = true` (e um
`benchmark_instance_types` não-vazio, ex.: `["c5.2xlarge"]`) no `terraform.tfvars` e faça
`terraform apply`.

### Policy `vod-benchmark-invoke` (lambda:InvokeFunctionUrl)

Quando `enable_transcode_benchmark_harness = true`, o Terraform provisiona automaticamente
uma policy inline `vod-benchmark-invoke` no usuário `vod-storage-svc` (identidade
compartilhada `vod-storage-svc` gerenciada pelo módulo `iam-s3`). Essa policy concede
**exclusivamente** `lambda:InvokeFunctionUrl` na Function URL do orquestrador de benchmark
(`module.benchmark_trigger[0].function_arn`), condicionado a `lambda:FunctionUrlAuthType =
"AWS_IAM"` (SigV4 obrigatório — sem invoke anônimo).

**Caveat de identidade compartilhada:** o usuário `vod-storage-svc` também é usado pelo
serviço `streaming-distribution` para acesso ao S3. Isso significa que, quando o benchmark
está habilitado, a distribution tecnicamente ganha a capacidade de invocar o orquestrador
também. Esse escopo excessivo é aceitável no curto prazo.

**TODO (hardening futuro):** criar uma identidade IAM dedicada para o `platform-upload`,
separada da identidade de distribuição, de modo que a concessão de `lambda:InvokeFunctionUrl`
fique escopada exclusivamente ao serviço que precisa disparar o benchmark. Registrado como
`TODO` em `aws/main.tf` no recurso `aws_iam_user_policy.benchmark_invoke`.

---

## Próximo passo documentado (não implementado)

**CI/CD via GitHub Actions + OIDC:** assumir uma IAM Role federada (sem chave AWS no repo),
rodar `terraform plan` no PR e `apply` no merge; encadear os playbooks Ansible. Bootstrap:
criar o OIDC provider + Role. Ver `infra/ansible/README.md` e o spec.
