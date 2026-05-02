# Módulo 15 — CI/CD & Pipelines

> **Meta do módulo:** automatizar build, test, push de imagem e deploy com GitHub Actions para todos os componentes do stack de streaming — NestJS app, encoder worker, infraestrutura Terraform e atualização de AMI.

**Pré-requisitos:** módulos 08, 09, 11.

---

## 1. Conceitos

### 1.1 O que é CI/CD

- **CI (Continuous Integration)** — todo commit roda build + tests. Falha = pull request bloqueado.
- **CD (Continuous Delivery)** — branch `main` sempre em estado deployável. Deploy é manual.
- **Continuous Deployment** — todo merge em `main` deploya automaticamente para produção.

Para o projeto de streaming: CD Delivery para staging, Deployment manual (ou automático após staging) para prod.

### 1.2 Opções na AWS

| Ferramenta | Onde roda | Quando usar |
|------------|-----------|-------------|
| **GitHub Actions** | GitHub infra | App open source, equipe que já usa GitHub |
| **CodePipeline + CodeBuild** | AWS | Stack 100% AWS, integração com CodeCommit |
| **Bitbucket Pipelines** | Atlassian | Equipe que usa Bitbucket |
| **GitLab CI** | GitLab | Equipe que usa GitLab |

> Recomendação: **GitHub Actions** — ecossistema gigante, YAML simples, integração AWS via OIDC nativa.

### 1.3 OIDC vs Access Keys no CI

**NÃO use access keys fixas em CI.** Use OIDC:

- GitHub Actions assume uma IAM Role diretamente, sem credencial longa.
- Credencial expira em minutos.
- Sem secret rotation.
- Auditoria clara (quem assumiu, de qual repo, em qual branch).

```
GitHub Actions job
  → solicita token JWT ao GitHub
  → AWS STS troca JWT por credenciais temporárias (máx. 1h)
  → job usa credenciais
  → credenciais expiram
```

### 1.4 Estratégias de deploy

| Estratégia | O que é | Quando |
|------------|---------|--------|
| **Rolling** | Substitui instâncias/tasks gradualmente | Padrão ECS |
| **Blue/Green** | Novo env em paralelo, troca DNS/ALB | Zero downtime, rollback rápido |
| **Canary** | % do tráfego para nova versão | Validar antes de 100% |
| **Recreate** | Derruba tudo, sobe novo | Dev; jobs que não podem ter 2 versões |

Para o NestJS: **Blue/Green via CodeDeploy + ALB**. Para encoder worker: **Rolling** (simples).

### 1.5 Pipeline de vídeo via CI

Além de app + infra, a plataforma tem um "pipeline de ativos":

- Novo vídeo → disparo do SQS → encoding → publicação.

Isso é o pipeline de **dados** (módulo 10), não de código. Mas o CI também:
- Valida configurações de encoding ao fazer PR.
- Atualiza AMI do encoder quando há novo FFmpeg ou patch de OS.

---

## 2. Laboratório prático

### 🧪 Lab 15.1 — Configurar OIDC na AWS

```bash
# Cria identity provider para GitHub no IAM
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# Trust policy da role
cat > trust-github.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::$ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:SEU-ORG/SEU-REPO:*"
      }
    }
  }]
}
EOF

# Cria role com permissões específicas por escopo
aws iam create-role --role-name github-actions-deploy \
  --assume-role-policy-document file://trust-github.json

# Permissões mínimas para ECS + ECR + S3 + Terraform
aws iam attach-role-policy --role-name github-actions-deploy \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
```

### 🧪 Lab 15.2 — Workflow para NestJS (build + push ECR + deploy ECS)

```yaml
# .github/workflows/deploy-app.yml
name: Deploy NestJS App

on:
  push:
    branches: [main]
    paths: [app/**]
  workflow_dispatch:

env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: streaming/nestjs-app
  ECS_CLUSTER: streaming-prod
  ECS_SERVICE: nestjs-app

permissions:
  id-token: write   # para OIDC
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: app/package-lock.json

      - run: npm ci
        working-directory: app

      - run: npm run test:unit
        working-directory: app

      - run: npm run lint
        working-directory: app

  build-and-deploy:
    needs: test
    runs-on: ubuntu-latest
    environment: production

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/github-actions-deploy
          aws-region: ${{ env.AWS_REGION }}

      - name: Login ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, push
        id: build
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG app/
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          echo "image=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG" >> $GITHUB_OUTPUT

      - name: Update ECS task definition
        id: task-def
        uses: aws-actions/amazon-ecs-render-task-definition@v1
        with:
          task-definition: infra/ecs/task-definition.json
          container-name: app
          image: ${{ steps.build.outputs.image }}

      - name: Deploy to ECS
        uses: aws-actions/amazon-ecs-deploy-task-definition@v1
        with:
          task-definition: ${{ steps.task-def.outputs.task-definition }}
          service: ${{ env.ECS_SERVICE }}
          cluster: ${{ env.ECS_CLUSTER }}
          wait-for-service-stability: true
          wait-for-minutes: 10
```

### 🧪 Lab 15.3 — Workflow para Terraform

```yaml
# .github/workflows/terraform.yml
name: Terraform

on:
  pull_request:
    paths: [infra/**]
  push:
    branches: [main]
    paths: [infra/**]

permissions:
  id-token: write
  contents: read
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: infra

    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: '~1.8'

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/github-actions-terraform
          aws-region: us-east-1

      - run: terraform init

      - run: terraform validate

      # Checkov security scan
      - uses: bridgecrewio/checkov-action@v12
        with:
          directory: infra/
          framework: terraform
          quiet: true

      # Infracost cost estimate
      - uses: infracost/actions/setup@v3
        with:
          api-key: ${{ secrets.INFRACOST_API_KEY }}
      - run: |
          infracost breakdown --path . \
            --terraform-var-file environments/prod.tfvars \
            --format json --out-file /tmp/infracost.json
          infracost comment github \
            --path /tmp/infracost.json \
            --repo $GITHUB_REPOSITORY \
            --github-token ${{ github.token }} \
            --pull-request ${{ github.event.pull_request.number }} \
            --behavior update

      - name: Terraform Plan
        run: terraform plan -var-file=environments/prod.tfvars -out=tfplan

      - name: Comment plan on PR
        uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        with:
          script: |
            const plan = require('fs').readFileSync('infra/tfplan-output.txt', 'utf8');
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `**Terraform Plan:**\n\`\`\`\n${plan.slice(0,5000)}\n\`\`\``
            });

  apply:
    needs: plan
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: production
    defaults:
      run:
        working-directory: infra

    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: '~1.8'
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/github-actions-terraform
          aws-region: us-east-1
      - run: terraform init
      - run: terraform apply -var-file=environments/prod.tfvars -auto-approve
```

### 🧪 Lab 15.4 — Workflow para AMI do encoder (EC2 Image Builder ou Packer)

```yaml
# .github/workflows/encoder-ami.yml
name: Build Encoder AMI

on:
  workflow_dispatch:
    inputs:
      ffmpeg_version:
        description: 'FFmpeg version'
        default: '7.0'
  schedule:
    - cron: '0 4 1 * *'  # 1° de cada mês

jobs:
  build-ami:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ vars.AWS_ACCOUNT_ID }}:role/github-actions-packer
          aws-region: us-east-1

      - uses: hashicorp/setup-packer@v1

      - name: Build AMI
        run: |
          packer init encoder/
          packer build \
            -var "ffmpeg_version=${{ inputs.ffmpeg_version || '7.0' }}" \
            encoder/encoder.pkr.hcl

      - name: Update Launch Template
        run: |
          NEW_AMI=$(aws ec2 describe-images --owners self \
            --filters "Name=name,Values=encoder-gpu-*" \
            --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' --output text)
          aws ec2 create-launch-template-version \
            --launch-template-name encoder-gpu-lt \
            --source-version '$Latest' \
            --launch-template-data "{\"ImageId\":\"$NEW_AMI\"}"
          aws ec2 modify-launch-template \
            --launch-template-name encoder-gpu-lt \
            --default-version '$Latest'
```

**Packer template (`encoder/encoder.pkr.hcl`):**

```hcl
packer {
  required_plugins {
    amazon = { source = "github.com/hashicorp/amazon", version = "~> 1" }
  }
}

variable "ffmpeg_version" { type = string }

source "amazon-ebs" "encoder" {
  ami_name      = "encoder-gpu-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  instance_type = "g4dn.xlarge"
  region        = "us-east-1"

  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-kernel-*-x86_64"
      "virtualization-type" = "hvm"
    }
    owners      = ["amazon"]
    most_recent = true
  }

  temporary_iam_instance_profile_policies = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ]
  communicator = "none"  # usa SSM, sem SSH
}

build {
  sources = ["source.amazon-ebs.encoder"]

  provisioner "shell" {
    script = "scripts/install-ffmpeg.sh"
    environment_vars = ["FFMPEG_VERSION=${var.ffmpeg_version}"]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
```

### 🧪 Lab 15.5 — Blue/Green deploy com CodeDeploy

```hcl
# ECS service com Blue/Green
resource "aws_ecs_service" "nestjs" {
  # ...
  deployment_controller {
    type = "CODE_DEPLOY"  # habilita blue/green
  }
}

resource "aws_codedeploy_app" "nestjs" {
  compute_platform = "ECS"
  name             = "streaming-nestjs"
}

resource "aws_codedeploy_deployment_group" "nestjs" {
  app_name               = aws_codedeploy_app.nestjs.name
  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"
  deployment_group_name  = "streaming-nestjs-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.nestjs.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route { listener_arns = [aws_lb_listener.https.arn] }
      target_group { name = aws_lb_target_group.blue.name }
      target_group { name = aws_lb_target_group.green.name }
    }
  }
}
```

### 🧪 Lab 15.6 — Branch protection + environments

No GitHub:

1. **Settings → Environments → production**:
   - Required reviewers: 1+ aprovadores.
   - Wait timer: 5 minutos (tempo para cancelar).
   - Deployment branches: apenas `main`.

2. **Branch protection rules para `main`**:
   - Require PR review: 1 aprovador.
   - Require status checks: `test`, `terraform/validate`.
   - Require linear history.

---

## 3. Estrutura de workflows recomendada

```
.github/
└── workflows/
    ├── deploy-app.yml          # NestJS: test → build → push ECR → ECS deploy
    ├── terraform.yml           # plan em PR + apply em main
    ├── encoder-ami.yml         # build AMI mensal ou manual
    ├── encoder-worker.yml      # build worker.zip → S3 deploy bucket
    └── ci-checks.yml           # lint, test, segurança em todo PR
```

### Pipeline por componente

| Componente | Trigger | Passos |
|-----------|---------|--------|
| NestJS app | push `app/**` em main | test → build image → ECR → ECS rolling |
| Encoder worker | push `worker/**` em main | test → zip → S3 → trigger ASG refresh |
| Terraform | push `infra/**` | validate → plan (PR) → apply (main) |
| Encoder AMI | schedule mensal | Packer → nova AMI → update launch template |

---

## 4. Segurança no CI/CD

### Secrets management no GitHub

- **Repository secrets**: `AWS_ACCOUNT_ID`, `INFRACOST_API_KEY`.
- **Environment secrets** (prod): mais restritivos, só acessíveis no environment `production`.
- **Nunca** logar secrets em steps (`echo $SECRET`).

### Scan de segurança automático

```yaml
# Em ci-checks.yml
- name: Snyk scan
  uses: snyk/actions/node@master
  env:
    SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
  with:
    args: --severity-threshold=high

- name: Trivy container scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ steps.build.outputs.image }}
    severity: CRITICAL,HIGH
    exit-code: 1
```

### Least privilege para roles CI

**Role separada por responsabilidade:**
- `github-actions-deploy` — só ECR push + ECS update.
- `github-actions-terraform` — permissões Terraform (ampla, mas só do CI).
- `github-actions-packer` — EC2 criar/terminar instâncias temporárias.

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Access keys em secrets | Rotação difícil, vazamento | OIDC sempre |
| Deploy sem wait-for-stability | Pipeline verde, task falhando | `wait-for-service-stability: true` |
| Sem rollback automático | Bug crítico em prod manual | CodeDeploy auto rollback + health check |
| Terraform apply sem plan review | Mudança inesperada | Plan em PR, apply só em main |
| `latest` tag no ECS | Deploy inconsistente | Sempre git SHA |
| Sem branch protection | Push direto em main | Obrigatório para produção |
| Pipeline construindo imagem em prod | Lento, caro | Build em staging, promove mesmo imagem |
| Sem cache de dependências | npm ci em 3 min por build | `actions/cache` no node_modules |

**Custos GitHub Actions:**
- Repos públicos: grátis.
- Repos privados: 2000 minutos/mês grátis, ~US$ 0.008/min extra.
- Runner Linux (ubuntu-latest): 1 min = 1 minuto.
- Self-hosted runner na AWS: EC2 spot + GitHub Runner = ~US$ 0.01/job.

---

## 6. Checklist de domínio

- [ ] OIDC configurado: GitHub Actions assume IAM role sem access key.
- [ ] Workflow de app: testa, builda imagem com SHA, deploya ECS rolling.
- [ ] Workflow de Terraform: plan em PR, apply em main, com checkov + infracost.
- [ ] Branch protection com required checks ativo em `main`.
- [ ] Environment `production` no GitHub com required reviewers.
- [ ] Workflow de AMI do encoder rodando mensalmente.
- [ ] Scan de container com Trivy integrado.
- [ ] Rollback automático configurado (CodeDeploy ou ECS).
- [ ] Nunca há credenciais fixas no código ou nos logs do CI.

---

## 7. Recursos

**GitHub Actions:**
- [Documentação oficial](https://docs.github.com/actions)
- [aws-actions](https://github.com/aws-actions) — ações oficiais da AWS.
- [Workflow syntax reference](https://docs.github.com/actions/writing-workflows/workflow-syntax-for-github-actions)

**Packer:**
- [Packer docs](https://developer.hashicorp.com/packer/docs)

**Ferramentas:**
- [act](https://github.com/nektos/act) — roda GitHub Actions localmente.
- [Trivy](https://github.com/aquasecurity/trivy) — scanner de vulnerabilidades em containers.
- [Infracost](https://infracost.io/) — custo de infra antes de aplicar.

---

➡️ Próximo: **Módulo 16 — Projeto Final**.
