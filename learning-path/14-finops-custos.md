# Módulo 14 — FinOps & Gestão de Custos AWS

> **Meta do módulo:** entender como AWS cobra cada centavo, criar alertas proativos, tomar decisões de arquitetura baseadas em custo e estimar o TCO (Total Cost of Ownership) do ecossistema de streaming.

**Pré-requisitos:** módulos 01 (fundamentos de cobrança) e qualquer combinação dos módulos anteriores.

---

## 1. Conceitos

### 1.1 FinOps

FinOps é a prática de otimizar gastos em cloud alinhando equipes de **Engenharia, Finanças e Produto**. O princípio central: **quem cria os recursos é quem tem mais controle sobre o custo**. DevOps = quem mais influencia a fatura.

**Ciclo FinOps:**
1. **Inform** — visibilidade (quanto gasto, onde, por quê).
2. **Optimize** — ações de redução sem prejudicar SLA.
3. **Operate** — cultura, processo, accountability.

### 1.2 AWS Cost Explorer

Ferramenta principal de análise de custos. Filtros por:
- Serviço (`Amazon EC2`, `AWS Lambda`).
- Tag (`Project=streaming`).
- Conta (multi-conta via Organizations).
- Tipo de uso (On-Demand, Reserved, Spot).

**Reports salvos:** configure views recorrentes de "custo por serviço / semana".

**Cost Anomaly Detection:** ML que detecta gastos anômalos e alerta por e-mail/SNS.

### 1.3 AWS Budgets

| Tipo | O que monitora | Ação |
|------|---------------|------|
| **Cost budget** | Gasto em US$ | Email/SNS |
| **Usage budget** | Uso de unidade (ex: GB S3) | Email/SNS |
| **RI/SP budget** | Cobertura de instâncias reservadas | Email/SNS |
| **Budget actions** | Dispara ação (ex: IAM deny, ASG max=0) | Automático |

### 1.4 Reserved Instances (RI) e Savings Plans

Compromisso de uso em troca de desconto:

| | Flexibilidade | Desconto vs OD | Compromisso |
|---|--------------|----------------|-------------|
| **On-Demand** | Total | 0% | Nenhum |
| **Compute Savings Plan** | Alto (qualquer EC2/Fargate/Lambda) | ~66% | 1 ou 3 anos, $/h |
| **EC2 Instance Savings Plan** | Médio (família + região) | ~72% | 1 ou 3 anos |
| **Reserved Instance** | Baixo (tipo exato + região + AZ) | ~75% | 1 ou 3 anos |

> 💡 **Estratégia:** compre Compute Savings Plan para cobrir ~70% do baseline. Deixe 30% On-Demand para variação. **Nunca compre RI/SP sem 3 meses de histórico de uso.**

**Spot Instances:** sem compromisso, 60–90% desconto, pode ser interrompido. Ideal para encoding (módulo 10).

### 1.5 Cost Allocation Tags

Tags que aparecem no Cost Explorer como dimensões. **Criticas para atribuição de custo.**

Tags recomendadas:
- `Project` — projeto ou produto.
- `Environment` — dev / staging / prod.
- `Team` — time responsável.
- `CostCenter` — centro de custo para contabilidade.

Ativar no console: **Billing → Cost Allocation Tags → Ativar cada tag**.

> ⚠️ Tags levam 24h para aparecer no Cost Explorer. Recursos sem tag = custo "sem dono".

### 1.6 Principais "fontes de fatura surpresa"

| Serviço | Gotcha | Como evitar |
|---------|--------|-------------|
| **NAT Gateway** | US$ 32/mês fixo + US$ 0.045/GB | VPC endpoints; NAT instance em dev |
| **CloudFront egress** | US$ 0.085/GB na América do Norte | Cache hit alto (TTL longo + imutável) |
| **RDS Multi-AZ** | 2× preço base | Single-AZ em dev |
| **ElastiCache cluster** | ~US$ 30/mês mínimo even idle | Destruir em dev |
| **EC2 GPU parada** | US$ 380/mês 24/7 | scale-to-zero |
| **EBS snapshots** | US$ 0.05/GB/mês cumulativo | Lifecycle ou limpeza manual |
| **CloudWatch Logs sem retenção** | TB acumulando | `retention_in_days` sempre |
| **Elastic IPs ociosos** | US$ 3.6/IP/mês (2024+) | `release-address` ao destruir |
| **Data transfer cross-region** | US$ 0.02/GB cada lado | Manter stack na mesma região |
| **Secrets Manager** | US$ 0.40/secret/mês | Consolidar segredos por contexto |
| **RDS snapshots esquecidos** | US$ 0.095/GB/mês | Lifecycle automático |

### 1.7 AWS Pricing Calculator

Antes de criar qualquer novo componente: estime o custo em https://calculator.aws/

Exemplo para estimar pipeline de encoding:

- EC2 `g4dn.xlarge` Spot: US$ 0.16/h × 8h/dia × 20 dias = **US$ 25.60/mês**.
- S3 para output (100 GB Standard): **US$ 2.30/mês**.
- CloudFront (5 TB egress): **US$ 425/mês**.
- Total: **US$ 452.90/mês** para escala moderada.

---

## 2. Por que isso importa no streaming

Streaming tem custos **muito correlacionados com crescimento**:

- Mais usuários → mais tráfego CloudFront (maior custo).
- Mais conteúdo → mais storage S3 + mais encoding.
- Mais features → mais serviços AWS.

O risco de "sucesso mata o produto": plataforma cresce, fatura explode, margem vai a zero. Entender custos antes de crescer é o que separa produto sustentável de crise financeira.

---

## 3. Laboratório prático

### 🧪 Lab 14.1 — Budgets proativos via Terraform

```hcl
resource "aws_budgets_budget" "monthly_total" {
  name         = "streaming-monthly-total"
  budget_type  = "COST"
  limit_amount = "100"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }

  cost_filters = {
    TagKeyValue = "user:Project$streaming"
  }
}

resource "aws_ce_anomaly_monitor" "streaming" {
  name              = "streaming-anomaly-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "streaming" {
  name      = "streaming-anomaly-alert"
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["20"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
  frequency = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.streaming.arn]
  subscriber {
    address = var.alert_email
    type    = "EMAIL"
  }
}
```

### 🧪 Lab 14.2 — Cost Explorer: queries úteis

```bash
# Custo por serviço no mês atual
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups | sort_by(@, &Metrics.UnblendedCost.Amount) | reverse(@) | [0:10]' \
  --output table

# Custo por tag Project
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=TAG,Key=Project \
  --output json
```

### 🧪 Lab 14.3 — Infracost: custo antes de aplicar o Terraform

```bash
# Instala
brew install infracost
infracost auth login

# No diretório Terraform
infracost breakdown --path . --terraform-var-file environments/dev.tfvars

# Compara branch atual vs main
infracost diff --path . --compare-to main
```

Output mostrará custo estimado mensal de cada recurso e delta de mudanças. Integre no CI (módulo 15).

### 🧪 Lab 14.4 — Auto-shutdown de recursos de dev

```hcl
# Lambda que desliga RDS, ASG e ElastiCache fora do horário
resource "aws_scheduler_schedule" "dev_shutdown" {
  name = "dev-nightly-shutdown"

  flexible_time_window { mode = "OFF" }
  schedule_expression = "cron(0 23 * * ? *)"  # 23h UTC = 20h BRT

  target {
    arn      = aws_lambda_function.dev_shutdown.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
```

```js
// Lambda dev_shutdown
export const handler = async () => {
  if (process.env.ENVIRONMENT !== 'dev') return;

  // Para RDS
  await rds.stopDBInstance({ DBInstanceIdentifier: 'streaming-postgres-dev' }).promise();

  // Scale ASG para 0
  await autoscaling.setDesiredCapacity({
    AutoScalingGroupName: 'encoder-asg-dev',
    DesiredCapacity: 0,
  }).promise();

  console.log('Dev resources stopped');
};
```

### 🧪 Lab 14.5 — Compute Optimizer recommendations

```bash
# Habilita Compute Optimizer na conta
aws compute-optimizer update-enrollment-status --status Active --include-member-accounts

# Recomendações de EC2 (48-72h de dados necessários)
aws compute-optimizer get-ec2-instance-recommendations --query \
  'instanceRecommendations[].{Instance:instanceArn,Findings:finding,Recommendations:recommendationOptions[0].instanceType}' \
  --output table
```

### 🧪 Lab 14.6 — S3 Storage Lens

```bash
# Habilita lens padrão (grátis)
aws s3control put-storage-lens-configuration \
  --account-id $ACCOUNT \
  --config-id default-streaming \
  --storage-lens-configuration '{
    "Id":"default-streaming",
    "IsEnabled":true,
    "DataExport":{
      "S3BucketDestination":{
        "AccountId":"'$ACCOUNT'",
        "Arn":"arn:aws:s3:::streaming-storage-lens-'$ACCOUNT'",
        "Format":"CSV",
        "OutputSchemaVersion":"V_1"
      }
    },
    "AccountLevel":{"BucketLevel":{}},
    "Include":{"Buckets":["arn:aws:s3:::streaming-*"]}
  }'
```

Mostra buckets com objetos sem lifecycle, classes mais caras que o necessário, etc.

---

## 4. Modelo de custo mensal por fase do produto

### Fase 1: desenvolvimento (lab pessoal)
| Recurso | Config | Custo |
|---------|--------|-------|
| RDS Postgres | `t4g.micro` single-AZ (desligado à noite) | US$ 5 |
| ElastiCache | `t4g.micro` × 2 (desligado à noite) | US$ 10 |
| ECS Fargate | 0.25 vCPU / 512 MB × 1 task | US$ 5 |
| S3 | 10 GB + 50 GB videos | US$ 1.50 |
| CloudFront | 10 GB egress | US$ 1 |
| Outros | CloudWatch, SQS, Lambda | US$ 2 |
| **Total** | | **~US$ 25/mês** |

### Fase 2: beta (primeiros 1000 usuários)
| Recurso | Config | Custo |
|---------|--------|-------|
| RDS Postgres | `t4g.medium` multi-AZ | US$ 55 |
| ElastiCache | `t4g.medium` × 2 | US$ 60 |
| ECS Fargate | 0.5 vCPU / 1GB × 2-4 tasks | US$ 30 |
| EC2 GPU encoding | `g4dn.xlarge` spot (10h/mês) | US$ 1.6 |
| S3 | 500 GB | US$ 12 |
| CloudFront | 1 TB egress | US$ 85 |
| ALB + Route53 | | US$ 20 |
| **Total** | | **~US$ 265/mês** |

### Fase 3: produção (50k usuários ativos)
Estimativa: US$ 1.500–5.000/mês dependendo de:
- Quantidade de vídeo armazenado.
- Horas médias assistidas por usuário × custo de egress.
- Frequência de novos uploads.

> **Regra:** egress CloudFront é o maior custo em escala. Negocie o CloudFront Custom Price Agreement com AWS depois de US$ 5k/mês em egress (desconto de 20–50%).

---

## 5. Checklist de domínio

- [ ] Tenho 3 budgets configurados com alertas proativos (percentual + forecasted).
- [ ] Cost Anomaly Detection ativo.
- [ ] Todos recursos têm tag `Project` e `Environment`.
- [ ] Tags ativadas no Cost Allocation Tags.
- [ ] Sei usar Cost Explorer para filtrar custo por tag/serviço.
- [ ] Rodei Infracost no projeto Terraform.
- [ ] Dev tem auto-shutdown noturno.
- [ ] Conheço os 10 maiores destruidores de orçamento (tabela acima).
- [ ] Calculei estimativa de custo mensal para produção do projeto.
- [ ] Sei quando comprar Compute Savings Plan (após 3 meses de histórico).

---

## 6. Recursos

**Oficiais:**
- [AWS Pricing Calculator](https://calculator.aws/)
- [Cost Explorer](https://console.aws.amazon.com/cost-management/home)
- [AWS FinOps Guide](https://aws.amazon.com/finops/)
- [Trusted Advisor](https://console.aws.amazon.com/trustedadvisor/) — recomendações automáticas.

**Ferramentas:**
- [Infracost](https://infracost.io/) — custo de Terraform antes de aplicar.
- [Cloud Custodian](https://cloudcustodian.io/) — policies de compliance + cleanup.
- [ec2instances.info](https://ec2instances.info/) — comparação visual de instâncias.

**Comunidade:**
- [FinOps Foundation](https://www.finops.org/) — certificação FinOps Practitioner.
- Newsletter [Last Week in AWS](https://www.lastweekinaws.com/).

---

➡️ Próximo: **Módulo 15 — CI/CD & Pipelines**.
