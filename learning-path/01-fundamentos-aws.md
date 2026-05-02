# Módulo 01 — Fundamentos AWS

> **Meta do módulo:** entender o que é a AWS, criar uma conta segura, configurar acesso programático (CLI) e desenvolver a intuição de "como serviços AWS são cobrados e organizados".

**Pré-requisitos:** módulo 00 concluído (ambiente local pronto).

---

## 1. Conceitos

### 1.1 O que é a AWS?

AWS (Amazon Web Services) é uma **plataforma de cloud pública** — um conjunto de ~250 serviços que você consome sob demanda, pagando pelo uso, sem precisar comprar hardware.

Pense em AWS como um **shopping de serviços**: cada loja é um serviço (EC2 = aluguel de máquinas, S3 = aluguel de espaço de disco, SQS = aluguel de fila de mensagens). Você anda pelo shopping pegando o que precisa, e a fatura chega no fim do mês.

### 1.2 Modelo de responsabilidade compartilhada

A AWS é responsável por **segurança DA cloud** (datacenters, hardware, hipervisor, hipervisão das suas chamadas de API). Você é responsável por **segurança NA cloud** (configurar IAM, criptografar dados, controlar acesso, manter SO atualizado em EC2).

> 🧠 **Modelo mental:** AWS é a construtora do prédio (paredes, portas, fechaduras industriais). Você é o inquilino (escolhe quem tem chave, se tranca a porta, o que guarda no cofre).

### 1.3 Regiões e Availability Zones

- **Region** — uma localização geográfica (ex: `us-east-1` em Norte da Virgínia, `sa-east-1` em São Paulo). Cada região é **isolada** das outras. Recursos não atravessam regiões automaticamente.
- **Availability Zone (AZ)** — um (ou conjunto de) datacenter dentro de uma região. Cada região tem 3+ AZs (ex: `us-east-1a`, `us-east-1b`, `us-east-1c`). AZs são fisicamente separadas (km de distância) mas conectadas por fibra de baixa latência.
- **Edge Location** — pontos de presença globais (mais que regiões), usados por CloudFront, Route53, Global Accelerator. Ficam mais perto dos usuários finais.

> 💡 **Dica:** para Brasil, `sa-east-1` (São Paulo) tem latência ótima mas é cerca de 30% mais cara que `us-east-1`. Para aprender, use `us-east-1` (mais barata, mais serviços, free tier generoso). Para produção destinada a usuários BR, use `sa-east-1`.

### 1.4 Conta, organização e usuário root

- **AWS Account** = unidade de cobrança e isolamento. Tudo dentro de uma conta é "vizinho" e tem que ser separado por IAM.
- **Root user** = o e-mail que você usou para criar a conta. Tem **acesso total e irrestrito**. Use **somente** para configuração inicial e billing. Depois, esqueça que existe (mas guarde a senha + MFA).
- **AWS Organizations** = você pode ter várias contas (uma para dev, uma para prod, uma para sandbox) sob uma org-master, com billing consolidado e SCPs (políticas que limitam o que cada conta pode fazer).

> ⚠️ **Cuidado:** comprometer o root user = perda total. Sempre MFA e senha forte de 20+ caracteres geradas em password manager.

### 1.5 Como a AWS cobra você

Modelos de cobrança comuns (você verá vários):

| Modelo | Exemplo | Como pensar |
|--------|---------|-------------|
| Por hora/segundo | EC2 (`t3.micro` ~ US$ 0.0104/h) | "Aluguel de hora" |
| Por requisição | Lambda (US$ 0.20 por 1M reqs), API Gateway | "Por click" |
| Por GB armazenado | S3 (~US$ 0.023/GB/mês `Standard`) | "Aluguel de espaço" |
| Por GB transferido | CloudFront, EC2 saída internet (~US$ 0.09/GB) | "Pedágio de saída" |
| Por unidade de capacidade | DynamoDB (RCU/WCU), Kinesis shards | "Throughput reservado" |
| Plano fixo + uso | Route53 (US$ 0.50/zona + queries), NAT GW | "Mensalidade + variável" |

**Regra geral:** **transferência de dados saindo da AWS para a internet é o que mais surpreende** em fatura. Dentro da mesma região e AZ, é grátis ou barato. Cross-region e saída internet são caros.

### 1.6 Free tier

Três tipos:
- **Always free** — sempre grátis até limite (ex: Lambda 1M reqs/mês, DynamoDB 25 GB).
- **12 meses free** — primeiros 12 meses da conta (ex: 750h/mês de EC2 `t2.micro`/`t3.micro`).
- **Trials** — 30 dias grátis em alguns serviços (ex: ElastiCache, Inspector).

Veja a tabela atualizada em: https://aws.amazon.com/free/

> ⚠️ **Cuidado:** **NAT Gateway, RDS Multi-AZ, NLB e Elastic IP NÃO estão no free tier**. Esses são clássicos de fatura surpresa.

---

## 2. Por que isso importa no streaming

Plataformas de streaming têm 3 perfis de custo dominantes:

1. **Storage de mídia** (S3) — vídeos originais + transcodificados. GBs ou TBs.
2. **Egress** (CloudFront) — banda saindo para o usuário final. Geralmente o **maior custo** de uma plataforma de streaming.
3. **Compute de encoding** (MediaConvert, EC2/ECS) — picos quando há novos uploads.

Se você não entender o modelo de cobrança da AWS, vai escolher arquiteturas tecnicamente corretas mas **financeiramente inviáveis** (ex: trafegar vídeo cross-region, encodar em CPU em vez de GPU/MediaConvert, deixar Multi-AZ desnecessário em ambiente dev).

---

## 3. Laboratório prático

### 🧪 Lab 1.1 — Criar a conta e proteger o root

1. Acesse https://aws.amazon.com/ → "Create an AWS Account".
2. Use e-mail dedicado (ex: `aws-streaming@seudominio.com` ou `seunome+aws@gmail.com`).
3. Senha: 20+ caracteres, gerada em password manager (1Password, Bitwarden, KeePassXC).
4. Cartão: vincule um cartão com limite controlado (Nubank Ultravioleta, virtual da Inter, etc).
5. Selecione plano **Basic Support** (gratuito).

**Após login:**

1. Vá em **IAM → Dashboard**.
2. Em "Security recommendations" verifique se aparece "Add MFA for root user". Clique em **Add MFA**.
3. Escolha **Authenticator app** (Authy, Google Authenticator, 1Password TOTP).
4. Cadastre 2 dispositivos MFA (um físico/celular + um backup, se possível).
5. Ative o **MFA Delete em buckets S3 críticos** (você fará isso no módulo 04).

### 🧪 Lab 1.2 — Configurar billing alerts

1. Faça login na conta root.
2. Top-right → seu nome → **Billing and Cost Management**.
3. **Billing preferences** → marque:
   - "Receive PDF invoice by email"
   - "Receive Free Tier usage alerts" (e-mail dedicado)
   - "Receive Billing alerts"
4. **Budgets → Create budget**:
   - Tipo: **Cost budget**
   - Período: **Monthly**, Recurring
   - Valor: **US$ 5** (depois você cria de US$ 10 e US$ 50)
   - Alerta em **80%** e **100%** do valor (actual)
   - E-mail destino: o seu

> 💡 **Dica:** crie 3 budgets (5, 10, 50). Se você toma US$ 5 nos primeiros dias, algo está errado. US$ 50 é teto absoluto para laboratório do curso.

### 🧪 Lab 1.3 — Criar usuário IAM administrativo (parar de usar root)

> **Importante:** a partir daqui você nunca mais vai logar com root para tarefas do dia a dia.

1. **IAM → Users → Create user**.
2. Nome: `seu-nome-admin`.
3. Marque "Provide user access to the AWS Management Console".
4. Console password: "Custom password" + senha forte. Marque "Users must create a new password..." se quiser forçar troca.
5. Em **Permissions options** → **Attach policies directly** → marque **`AdministratorAccess`**.
6. Crie o usuário. Anote a **URL de login** mostrada (ex: `https://123456789012.signin.aws.amazon.com/console`).

**Logout** → **Login com o novo usuário** → ative MFA também.

> ⚠️ **Cuidado:** `AdministratorAccess` é grande demais para qualquer pessoa real em produção. Para o laboratório está OK, mas vamos refinar isso no módulo 03 (IAM).

### 🧪 Lab 1.4 — Configurar a AWS CLI

1. **IAM → Users → seu-nome-admin → Security credentials → Create access key**.
2. Caso de uso: **Command Line Interface (CLI)** → confirme.
3. Anote a **Access Key ID** e a **Secret Access Key** (a Secret só aparece uma vez!).

No terminal local:

```bash
$ aws configure --profile streaming-admin
AWS Access Key ID:     <cole>
AWS Secret Access Key: <cole>
Default region name:   us-east-1
Default output format: json
```

Teste:

```bash
$ aws sts get-caller-identity --profile streaming-admin
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/seu-nome-admin"
}
```

Se aparecer seu ARN, está funcionando.

> 💡 **Dica avançada:** depois do módulo 03, troque essa autenticação por **IAM Identity Center (SSO)** + perfis CLI temporários. Access keys longevas são um anti-padrão moderno.

### 🧪 Lab 1.5 — Tag policy global

Antes de criar qualquer recurso, defina suas tags:

| Chave | Valor recomendado | Por que |
|-------|-------------------|---------|
| `Project` | `streaming-learning` | Filtrar custos do curso |
| `Environment` | `lab`, `dev`, `prod` | Separar ambientes |
| `Owner` | `seu-email` | Quem criou |
| `ManagedBy` | `console`, `cli`, `terraform` | Como foi criado |

Configure no **Cost Explorer → Cost Allocation Tags** para que essas tags apareçam nos relatórios (demora 24h para começar a aparecer).

### 🧪 Lab 1.6 — Hello world: um bucket S3 e um delete

```bash
# Cria
$ aws s3 mb s3://streaming-lab-$(aws sts get-caller-identity --query Account --output text) --profile streaming-admin

# Lista
$ aws s3 ls --profile streaming-admin

# Deleta
$ aws s3 rb s3://streaming-lab-XXXXXXXX --profile streaming-admin
```

Parabéns, você criou e destruiu seu primeiro recurso AWS via CLI.

---

## 4. Armadilhas e custos

| Armadilha | Sintoma | Como evitar |
|-----------|---------|-------------|
| Esquecer recurso ligado | Fatura crescente sem motivo aparente | Cost Explorer diário; tags; destruir labs |
| Subir RDS Multi-AZ "para testar" | US$ 100+/mês com banco vazio | Em lab use Single-AZ db.t3.micro |
| NAT Gateway esquecido | US$ 32/mês fixo + data processing | Use NAT instance ou destrua VPC após lab |
| Public IPs alocados sem uso | US$ 3.6/mês por IP ocioso (mudou em 2024) | Liberar Elastic IPs após uso |
| Logs CloudWatch sem retenção | TB acumulando = fatura silenciosa | Sempre setar retenção (7-30 dias em lab) |
| Cross-region transfer | Egress invisível | Manter recursos na mesma região |
| Snapshot RDS abandonado | US$ 0.095/GB/mês indefinidamente | Lifecycle automático ou limpeza manual |

> ⚠️ **Top 3 destruidores de orçamento no início:** NAT Gateway, RDS Multi-AZ, e dados saindo via egress. Memorize.

---

## 5. Glossário rápido (volte aqui sempre)

- **ARN** (Amazon Resource Name) — identificador único de qualquer recurso AWS. Formato: `arn:aws:<service>:<region>:<account>:<resource-type>/<id>`.
- **Endpoint** — URL para chamar um serviço (ex: `s3.us-east-1.amazonaws.com`).
- **Service quota / limit** — limite por conta/região (ex: 5 VPCs por região por padrão). Aumentável via ticket.
- **API throttling** — quando você bate em limite de chamadas por segundo. Resposta: backoff exponencial.
- **Resource policy** vs **Identity policy** — política anexada ao recurso (ex: bucket policy) vs anexada ao principal (ex: usuário).
- **Principal** — quem está fazendo a chamada (usuário, role, serviço).
- **Eventual consistency** — alguns serviços demoram milissegundos a segundos para propagar mudanças (S3 ListBucket após PutObject costumava ser, hoje é forte para a maioria das operações).

---

## 6. Checklist de domínio

- [ ] Sei a diferença entre Region, AZ e Edge Location e dou exemplo de quando cada uma importa.
- [ ] Conheço pelo menos 5 modelos de cobrança AWS e dou um serviço de exemplo de cada.
- [ ] Configurei MFA no root **e** no usuário admin.
- [ ] Tenho budgets de US$ 5, 10 e 50 com alerta por e-mail.
- [ ] AWS CLI funciona com profile nomeado (não usa profile `default`).
- [ ] Sei quais recursos NÃO estão no free tier (NAT GW, RDS Multi-AZ, NLB, etc).
- [ ] Defini meu schema de tags e o aplico em todo recurso criado.
- [ ] Consegui criar e destruir um bucket via CLI.

---

## 7. Recursos

**Oficiais:**
- [AWS Free Tier](https://aws.amazon.com/free/)
- [AWS Pricing Calculator](https://calculator.aws/)
- [Well-Architected Framework](https://aws.amazon.com/architecture/well-architected/) — leia depois do módulo 03.
- [AWS Documentation Index](https://docs.aws.amazon.com/)

**Cursos / vídeos:**
- AWS Skill Builder — "AWS Cloud Quest: Cloud Practitioner" (gamificado e gratuito).
- "AWS for Beginners" no canal freeCodeCamp (YouTube).

**Livros:**
- _AWS Cookbook_ (O'Reilly) — receitas práticas.
- _The AWS Well-Architected Framework Lens_ (PDF gratuito da AWS).

**Sobre custos:**
- Newsletter [Last Week in AWS](https://www.lastweekinaws.com/) (Corey Quinn) — humorada e técnica sobre cobrança AWS.

---

➡️ Próximo: **Módulo 02 — Networking & VPC**.
