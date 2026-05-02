# Módulo 11 — Terraform

> **Meta do módulo:** codificar toda a infraestrutura em Terraform — state remoto, módulos, workspaces — e subir o stack de streaming do zero com um único `terraform apply`.

**Pré-requisitos:** módulos 01–10 (você entende o que vai codificar).

---

## 1. Conceitos

### 1.1 Por que Infraestrutura como Código (IaC)

- **Reprodutibilidade** — criar um ambiente staging idêntico ao prod em minutos.
- **Auditoria** — todo recurso criado tem git blame (quem mudou o quê, quando).
- **Rollback** — reverter infra como reverter código.
- **Revisão** — PR de infra com terraform plan como diff.
- **Documentação viva** — o código descreve o que existe (vs diagrama desatualizado).

### 1.2 Terraform vs CloudFormation vs CDK vs Pulumi

| | Terraform | CloudFormation | CDK | Pulumi |
|---|-----------|---------------|-----|--------|
| Linguagem | HCL | YAML/JSON | TypeScript/Python | TypeScript/Python |
| Multi-cloud | ✅ | ❌ (AWS only) | ❌ | ✅ |
| Comunidade | Enorme | Boa | Boa | Crescendo |
| State | Local/remoto | Gerenciado pela AWS | Gerenciado pela AWS | Backend plugável |
| Quando escolher | Multi-cloud, equipe mixed | AWS only, legacy | Devs sem HCL | Devs que querem código real |

> Para AWS com equipe nova: **Terraform** tem o maior ecossistema de módulos e tutoriais.

### 1.3 Ciclo de vida Terraform

```
terraform init      # download providers + configura backend
terraform plan      # diff entre state e desejado
terraform apply     # aplica mudanças na nuvem
terraform destroy   # destroi tudo
terraform state     # manipula state diretamente
```

### 1.4 Blocos fundamentais HCL

```hcl
# Providers
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = {
      Project     = "streaming"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# Variáveis
variable "region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type = string
}

# Recursos
resource "aws_s3_bucket" "uploads" {
  bucket = "streaming-${var.environment}-uploads-${data.aws_caller_identity.current.account_id}"
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}

# Outputs
output "uploads_bucket_name" {
  value = aws_s3_bucket.uploads.id
}

# Locals
locals {
  prefix = "streaming-${var.environment}"
  azs    = slice(data.aws_availability_zones.available.names, 0, 2)
}
```

### 1.5 State — o coração do Terraform

**State** = mapeamento entre recursos HCL e recursos reais na AWS. Armazenado em `terraform.tfstate`.

**State remoto (obrigatório em equipes):**

```hcl
terraform {
  backend "s3" {
    bucket         = "terraform-state-123456789"
    key            = "streaming/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

- **S3** guarda o arquivo de state.
- **DynamoDB** garante lock (previne 2 `apply` simultâneos).

> ⚠️ **State contém segredos em texto puro** (passwords RDS, etc). Use S3 com SSE-KMS + restrição de acesso.

### 1.6 Módulos

Módulo = diretório de arquivos `.tf` reutilizáveis.

```hcl
# Uso
module "vpc" {
  source = "./modules/vpc"    # local
  # source = "terraform-aws-modules/vpc/aws"  # registry
  # version = "~> 5.0"

  cidr            = "10.0.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
```

**Módulos públicos do Registry:**
- `terraform-aws-modules/vpc/aws` — VPC completa.
- `terraform-aws-modules/ecs/aws` — ECS.
- `terraform-aws-modules/rds/aws` — RDS.
- `terraform-aws-modules/alb/aws` — ALB.

### 1.7 Workspaces

Ambientes isolados no mesmo backend:

```bash
terraform workspace new dev
terraform workspace new staging
terraform workspace new prod
terraform workspace select prod
terraform plan -var-file=environments/prod.tfvars
```

> Cada workspace tem state próprio. Variáveis sensíveis ficam em `prod.tfvars` (nunca versionado) ou em ambiente/CI.

### 1.8 Boas práticas

```
infra/
├── environments/
│   ├── dev.tfvars
│   ├── staging.tfvars
│   └── prod.tfvars        # (gitignored ou secrets masked)
├── modules/
│   ├── networking/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── ecs-service/
│   ├── rds/
│   └── encoder-worker/
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
└── backend.tf
```

---

## 2. Laboratório prático

### 🧪 Lab 11.1 — Bootstrap do state remoto

Execute UMA VEZ manualmente antes de usar Terraform:

```bash
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"

# Bucket de state
aws s3 mb s3://tf-state-$ACCOUNT-$REGION
aws s3api put-bucket-versioning --bucket tf-state-$ACCOUNT-$REGION \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket tf-state-$ACCOUNT-$REGION \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# DynamoDB lock table
aws dynamodb create-table \
  --table-name terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 🧪 Lab 11.2 — Estrutura básica do projeto

```bash
mkdir -p infra/{modules/{networking,rds,ecs-service,encoder},environments}
```

**`infra/versions.tf`:**
```hcl
terraform {
  required_version = "~> 1.8"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.50" }
  }
}
```

**`infra/backend.tf`:**
```hcl
terraform {
  backend "s3" {
    bucket         = "tf-state-<ACCOUNT>-us-east-1"
    key            = "streaming/${terraform.workspace}/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}
```

**`infra/variables.tf`:**
```hcl
variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}
```

**`infra/environments/dev.tfvars`:**
```hcl
environment = "dev"
region      = "us-east-1"
vpc_cidr    = "10.0.0.0/16"
```

### 🧪 Lab 11.3 — Módulo networking

**`infra/modules/networking/main.tf`:**
```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "public" {
  count             = length(var.public_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.public_cidrs[count.index]
  availability_zone = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-public-${count.index + 1}" }
}

resource "aws_subnet" "private" {
  count             = length(var.private_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = { Name = "${var.name}-private-${count.index + 1}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# S3 Gateway Endpoint (grátis)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
  tags = { Name = "${var.name}-s3-endpoint" }
}
```

**`infra/modules/networking/variables.tf`:**
```hcl
variable "name"          { type = string }
variable "cidr"          { type = string }
variable "azs"           { type = list(string) }
variable "public_cidrs"  { type = list(string) }
variable "private_cidrs" { type = list(string) }
variable "region"        { type = string }
```

**`infra/modules/networking/outputs.tf`:**
```hcl
output "vpc_id"          { value = aws_vpc.this.id }
output "public_subnets"  { value = aws_subnet.public[*].id }
output "private_subnets" { value = aws_subnet.private[*].id }
```

### 🧪 Lab 11.4 — main.tf que orquestra tudo

```hcl
# infra/main.tf
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "streaming"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_availability_zones" "available" {}
data "aws_caller_identity" "current" {}

locals {
  name = "streaming-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "networking" {
  source        = "./modules/networking"
  name          = local.name
  cidr          = var.vpc_cidr
  region        = var.region
  azs           = local.azs
  public_cidrs  = [cidrsubnet(var.vpc_cidr, 8, 1), cidrsubnet(var.vpc_cidr, 8, 2)]
  private_cidrs = [cidrsubnet(var.vpc_cidr, 8, 11), cidrsubnet(var.vpc_cidr, 8, 12)]
}

# S3 buckets
resource "aws_s3_bucket" "uploads" {
  bucket = "${local.name}-uploads-${data.aws_caller_identity.current.account_id}"
}
resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  block_public_acls   = true
  ignore_public_acls  = true
  block_public_policy = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id
  versioning_configuration { status = "Enabled" }
}

# SQS
resource "aws_sqs_queue" "encoder_dlq" {
  name = "${local.name}-encoder-dlq"
  message_retention_seconds = 1209600
}
resource "aws_sqs_queue" "encoder_jobs" {
  name = "${local.name}-encoder-jobs"
  visibility_timeout_seconds = 600
  receive_wait_time_seconds  = 20
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.encoder_dlq.arn
    maxReceiveCount     = 3
  })
}

# Outputs
output "uploads_bucket" { value = aws_s3_bucket.uploads.id }
output "encoder_queue"  { value = aws_sqs_queue.encoder_jobs.url }
output "vpc_id"         { value = module.networking.vpc_id }
```

### 🧪 Lab 11.5 — Init, plan, apply

```bash
cd infra
terraform init
terraform workspace new dev
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars
```

Saída esperada: VPC, subnets, S3, SQS criados.

### 🧪 Lab 11.6 — Gerenciando drift

```bash
# Importar recurso criado manualmente
terraform import aws_s3_bucket.uploads streaming-dev-uploads-123456789

# Ver estado
terraform state list
terraform state show aws_s3_bucket.uploads

# Remover do state sem destruir o recurso real
terraform state rm aws_s3_bucket.uploads
```

### 🧪 Lab 11.7 — terraform-docs

Gera documentação automática de módulos:

```bash
brew install terraform-docs
terraform-docs markdown table ./modules/networking > modules/networking/README.md
```

---

## 3. Boas práticas avançadas

### Terragrunt (DRY)

Para múltiplos ambientes sem duplicar configuração:

```hcl
# terragrunt.hcl (raiz)
remote_state {
  backend = "s3"
  generate = { path = "backend.tf", if_exists = "overwrite" }
  config = {
    bucket = "tf-state-${get_aws_account_id()}"
    key    = "${path_relative_to_include()}/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "terraform-locks"
  }
}
```

### Protect de recursos críticos

```hcl
resource "aws_rds_cluster" "main" {
  # ...
  lifecycle {
    prevent_destroy = true
  }
}
```

### Sensitive variables

```hcl
variable "db_password" {
  type      = string
  sensitive = true   # não aparece em plan/apply output
}
```

### Checkov (segurança estática)

```bash
pip install checkov
checkov -d . --framework terraform
```

Detecta S3 sem encryption, SGs muito abertos, etc.

---

## 4. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| State local em máquina dev | Conflito em equipe / perda | Backend S3 + DynamoDB lock |
| State sem encrypt | Segredos expostos | `encrypt=true` + KMS |
| `terraform destroy` sem `prevent_destroy` | Banco de prod deletado | lifecycle prevent_destroy em prod |
| `count` vs `for_each` | Remoção de item do meio recria todos | Prefira `for_each` com mapa |
| Provider sem version pin | `init` pega versão major diferente | `version = "~> 5.50"` |
| Plan na branch sem review | Bug vai pra prod direto | Atlantis / Terraform Cloud + PR policy |
| Secrets em tfvars versionados | Vaza credentials | tfvars no .gitignore + AWS Secrets Manager |
| Module sem outputs | Dependências hardcoded | Sempre expor outputs |

**Custos do Terraform em si:** grátis. Terraform Cloud free tier: 500 recursos gerenciados. HCP Terraform Plus: US$ 20/usuário/mês.

---

## 5. Checklist de domínio

- [ ] Criei backend S3 + DynamoDB lock.
- [ ] Escrevi módulo `networking` com inputs/outputs bem definidos.
- [ ] Uso `default_tags` no provider para tagging automático.
- [ ] Tenho `tfvars` por ambiente.
- [ ] Consigo rodar `plan` e interpretar o diff antes de `apply`.
- [ ] Importei recurso criado manualmente.
- [ ] Usei `prevent_destroy` em recurso crítico.
- [ ] Rodei Checkov (ou tflint) sem erros críticos.
- [ ] Módulos com README gerado por terraform-docs.

---

## 6. Recursos

**Oficiais:**
- [Terraform docs](https://developer.hashicorp.com/terraform/docs)
- [AWS Provider docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [terraform-aws-modules](https://github.com/terraform-aws-modules) — módulos oficiais.

**Ferramentas:**
- `tflint` — linter de HCL.
- `checkov` — segurança estática.
- `terraform-docs` — documentação automática.
- `infracost` — custo de infra antes de aplicar.
- `atlantis` — PRs de Terraform com plan automático.

**Livros:**
- _Terraform: Up & Running_ — Yevgeniy Brikman (O'Reilly). 3ª edição.

---

➡️ Próximo: **Módulo 12 — Observabilidade**.
