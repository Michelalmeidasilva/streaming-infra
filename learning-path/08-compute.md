# Módulo 08 — Compute (EC2, ECS/Fargate, Lambda, API Gateway)

> **Meta do módulo:** entender as três famílias de compute na AWS, escolher a certa para cada caso, e subir cada uma na prática. Incluindo as instâncias GPU que vão fazer transcoding no módulo 10.

**Pré-requisitos:** módulos 02, 03, 07.

---

## 1. Conceitos

### 1.1 Os três paradigmas

| Paradigma | Exemplo AWS | Você gerencia | Cobrança |
|-----------|-------------|---------------|----------|
| **VM** | EC2 | OS, runtime, app, scaling | Por hora/segundo da VM |
| **Container** | ECS Fargate, EKS | Imagem, app, scaling config | Por vCPU+RAM/segundo |
| **Function** | Lambda | Código + deps | Por invocação + GB-segundo |

> 🧠 **Modelo mental:**
> - EC2 = você aluga uma máquina virtual e faz o que quiser.
> - ECS Fargate = você empacota um contêiner; AWS roda em "máquinas que você não vê".
> - Lambda = você manda só uma função; AWS roda quando alguém chama, escala automático.

### 1.2 EC2 — Elastic Compute Cloud

**Conceitos chave:**

- **AMI** (Amazon Machine Image) — imagem do disco. Amazon Linux 2023, Ubuntu 22.04, Windows, AMIs customizadas.
- **Instance type** — tamanho/CPU/RAM/rede (ex: `t3.micro`, `m7g.large`, `g5.xlarge`).
- **Instance family** — sufixos importantes:
  - `t` = burst (general purpose, baseline + créditos).
  - `m` = balanced (general purpose).
  - `c` = compute optimized (mais CPU/$ ).
  - `r` = memory optimized.
  - `g`, `p` = GPU (`g4dn`, `g5`, `p4d`).
  - `i` = IO optimized (NVMe SSD local).
  - Geração com `g` no nome (ex: `m7g`) = **Graviton ARM** — 20–40% mais barato e perfomante. Use sempre que app suportar.
- **EBS** = disco em rede persistente (`gp3` recomendado).
- **Instance store** = SSD local efêmero (perde no stop).
- **User data** = script bash que roda no boot.
- **Instance profile** = role IAM anexada à instância.
- **Auto Scaling Group (ASG)** = conjunto de instâncias gerenciadas (scale in/out).

**Modelos de cobrança:**

| | Custo | Quando |
|---|------|--------|
| **On-Demand** | ✕1 | Sem compromisso |
| **Reserved Instance / Savings Plan** | -40% a -75% | Workload estável 1–3 anos |
| **Spot** | -50% a -90% | Workload tolerante a interrupção (encoding!) |
| **Dedicated host/instance** | mais caro | Compliance que exige isolamento |

> 💡 **Spot é o segredo do encoding barato.** Workers de transcodificação batch são candidatos perfeitos: se interrompido, mensagem volta pra fila e outro worker pega.

### 1.3 GPU instances (relevantes p/ encoding de vídeo)

| Família | GPU | Uso |
|---------|-----|-----|
| `g4dn` | NVIDIA T4 | Encoding via **NVENC** (mais usado), inferência ML |
| `g5` | NVIDIA A10G | Encoding mais rápido, ML maior |
| `g6` / `g6e` | NVIDIA L4 / L40S | Geração nova, melhor relação custo/throughput |
| `p4d` / `p5` | A100 / H100 | Treinamento ML pesado (não encoding) |

Para FFmpeg com NVENC:

```
ffmpeg -hwaccel cuda -i in.mp4 \
  -c:v h264_nvenc -preset p4 -b:v 5M \
  -c:a aac -b:a 128k out.mp4
```

> No módulo 10, vamos rodar exatamente isso em uma `g4dn.xlarge` Spot consumindo SQS.

### 1.4 ECS — Elastic Container Service

Orquestrador de contêineres da AWS, dois "launch types":

- **Fargate** — serverless. Você define CPU+RAM, AWS roda. Não administra EC2.
- **EC2** — você administra ASG de EC2 que ECS usa como "fleet".

**Conceitos:**

- **Task definition** — receita do contêiner (imagem, CPU, RAM, env, role, port mapping).
- **Task** — uma instância rodando da task definition (efêmera).
- **Service** — desired count + ALB integration + rolling deploy. Mantém N tasks rodando.
- **Cluster** — boundary lógico (geralmente 1 por ambiente).

> 💡 **ECS Fargate é o sweet spot para apps web modernas.** Sem patching, escala fácil, integra bem com ALB e CloudWatch.

### 1.5 EKS (mencionado por completude)

Kubernetes gerenciado. Escolha apenas se já tem familiaridade e/ou ecossistema K8s pesado (Helm, Argo, Istio). Em laboratório de streaming, **fica mais simples com ECS**.

### 1.6 Lambda

**Function-as-a-Service.** Você manda zip ou imagem de contêiner, AWS roda quando trigger ativa.

**Características:**

- **Cold start** — primeira invocação demora (Node.js: 100–400ms; Java: 500–2000ms).
- **Memory** = 128 MB a 10 GB. CPU é proporcional à RAM.
- **Timeout** = até 15 minutos.
- **Triggers** = API Gateway, SQS, SNS, S3, DynamoDB Stream, EventBridge, IoT, etc.
- **Deployment package** = zip (até 50 MB direto / 250 MB unzipped) ou imagem ECR (até 10 GB).
- **Layers** = bibliotecas compartilhadas entre funções (até 5 layers por função).
- **Provisioned concurrency** — pré-aquece N instâncias (sem cold start). Custa.

**Custos:** US$ 0.20 por 1M reqs + US$ 0.0000166667 por GB-segundo. 1M reqs + 400k GB-s grátis/mês.

### 1.7 Lambda em VPC (cuidados)

Lambda fora da VPC tem internet de graça. **Em VPC**, precisa NAT GW para internet (ou VPC endpoints). ENIs criadas sob demanda; não há mais cold start adicional desde 2019.

### 1.8 API Gateway

**Quem você apresenta sua API para a internet:**

- **REST API** — features completas (caching, request validation, models, throttling fino). Mais caro.
- **HTTP API** — barato, rápido, menos features. **Use quando puder**.
- **WebSocket API** — tempo real (chat, notificações).

**Componentes:**

- **Route** (HTTP API) ou **Resource + Method** (REST API).
- **Integration** — destino (Lambda, ALB, NLB, HTTP arbitrário, AWS service direto).
- **Authorizer** — Cognito User Pool, JWT, Lambda authorizer, IAM SigV4.
- **Stages** = ambientes (`dev`, `prod`).

**Custo:** HTTP API US$ 1/M reqs (até 300M); REST API US$ 3.50/M.

### 1.9 Application Load Balancer (ALB)

Camada 7 (HTTP/HTTPS) load balancer. Roteamento por path, host, header. Integra com ECS service, EC2, Lambda como target.

**Conceitos:**

- **Target group** = grupo de instâncias/IPs/containers receivendo tráfego, com health check.
- **Listener** = porta + protocolo + ações.
- **Rule** = condição → ação.

**Custo:** US$ 0.0225/h (~US$ 16/mês) + LCU (Load Balancer Capacity Units).

---

## 2. Por que isso importa no streaming

Mapa de compute na nossa plataforma:

| Componente | Compute |
|-----------|---------|
| **NestJS SSR app** (módulo 09) | ECS Fargate atrás de ALB; ou EC2 + ASG se preferir controle |
| **Workers de encoding** (módulo 10) | EC2 GPU `g4dn`/`g5` Spot consumindo SQS |
| **APIs internas / triggers** | Lambda (autenticação, presigned URL gen, S3 → SQS, callbacks) |
| **Webhooks externos** (Stripe etc) | API Gateway HTTP API → Lambda |
| **Auth** | Cognito + Lambda triggers |
| **Tarefas batch** (cleanup, relatórios) | Lambda + EventBridge Scheduler ou ECS Scheduled Tasks |

---

## 3. Laboratório prático

### 🧪 Lab 8.1 — EC2 com user-data e SSM

```bash
# Pega AMI Amazon Linux 2023 mais recente
AMI=$(aws ec2 describe-images --owners amazon \
  --filters Name=name,Values=al2023-ami-*-kernel-*-x86_64 \
            Name=architecture,Values=x86_64 \
  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' --output text)

# Role com SSM agent
aws iam create-role --role-name ec2-ssm-role --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
aws iam attach-role-policy --role-name ec2-ssm-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name ec2-ssm-profile
aws iam add-role-to-instance-profile --instance-profile-name ec2-ssm-profile --role-name ec2-ssm-role

# User data
cat > userdata.sh <<'EOF'
#!/bin/bash
dnf update -y
dnf install -y nginx
systemctl enable --now nginx
echo "<h1>Streaming lab</h1>" > /usr/share/nginx/html/index.html
EOF

# Instância
aws ec2 run-instances --image-id $AMI \
  --instance-type t3.micro \
  --subnet-id $PUB_A \
  --security-group-ids $SG_PUBLIC_WEB \
  --iam-instance-profile Name=ec2-ssm-profile \
  --user-data file://userdata.sh \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=streaming-web-lab},{Key=Project,Value=streaming-learning}]' \
  --metadata-options 'HttpTokens=required'
```

> **`HttpTokens=required`** força IMDSv2 (proteção contra SSRF clássico).

```bash
# Conecte via SSM (sem chave SSH)
aws ssm start-session --target i-xxxxx
```

### 🧪 Lab 8.2 — Spot instance para worker

```bash
aws ec2 run-instances --image-id $AMI \
  --instance-type g4dn.xlarge \
  --subnet-id $PRIV_A \
  --security-group-ids $SG_APP \
  --iam-instance-profile Name=encoder-profile \
  --instance-market-options '{"MarketType":"spot","SpotOptions":{"InstanceInterruptionBehavior":"terminate"}}' \
  --user-data file://encoder-bootstrap.sh
```

Spot pode ser interrompido com 2 min de aviso (metadata). Encoder lê esse aviso e devolve a mensagem SQS antes de morrer.

### 🧪 Lab 8.3 — ECS Fargate hello-world

```bash
# Cluster
aws ecs create-cluster --cluster-name streaming-lab \
  --capacity-providers FARGATE FARGATE_SPOT \
  --default-capacity-provider-strategy capacityProvider=FARGATE,weight=1

# Task definition
cat > task-def.json <<EOF
{
  "family": "hello-app",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT:role/ecsTaskExecutionRole",
  "containerDefinitions": [{
    "name": "web",
    "image": "public.ecr.aws/docker/library/nginx:alpine",
    "portMappings": [{"containerPort": 80}],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "/ecs/hello-app",
        "awslogs-region": "us-east-1",
        "awslogs-stream-prefix": "web",
        "awslogs-create-group": "true"
      }
    }
  }]
}
EOF

aws ecs register-task-definition --cli-input-json file://task-def.json

# Service (atrás de ALB criado a parte)
aws ecs create-service --cluster streaming-lab --service-name hello \
  --task-definition hello-app --desired-count 2 --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$PRIV_A,$PRIV_B],securityGroups=[$SG_APP],assignPublicIp=DISABLED}" \
  --load-balancers targetGroupArn=$TG_ARN,containerName=web,containerPort=80
```

### 🧪 Lab 8.4 — Lambda em Node.js + API Gateway

```bash
# 1. Código
mkdir hello-lambda && cd hello-lambda
cat > index.mjs <<'EOF'
export const handler = async (event) => ({
  statusCode: 200,
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ msg: "hello", time: new Date().toISOString() })
});
EOF
zip function.zip index.mjs

# 2. Role
aws iam create-role --role-name lambda-hello-role --assume-role-policy-document '{
  "Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}'
aws iam attach-role-policy --role-name lambda-hello-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# 3. Cria função
aws lambda create-function --function-name hello \
  --runtime nodejs20.x --handler index.handler \
  --zip-file fileb://function.zip \
  --role arn:aws:iam::$ACCOUNT:role/lambda-hello-role

# 4. HTTP API
API_ID=$(aws apigatewayv2 create-api --name hello-api --protocol-type HTTP \
  --target arn:aws:lambda:us-east-1:$ACCOUNT:function:hello \
  --query ApiId --output text)

# Permite API GW invocar
aws lambda add-permission --function-name hello --statement-id apigw \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:$ACCOUNT:$API_ID/*/*"

# Endpoint:
echo "https://$API_ID.execute-api.us-east-1.amazonaws.com/"
curl https://$API_ID.execute-api.us-east-1.amazonaws.com/
```

### 🧪 Lab 8.5 — Lambda triggered por SQS

```bash
# Permite Lambda ler da SQS
aws iam put-role-policy --role-name lambda-hello-role --policy-name sqs-read \
  --policy-document '{
    "Version":"2012-10-17",
    "Statement":[{"Effect":"Allow","Action":["sqs:ReceiveMessage","sqs:DeleteMessage","sqs:GetQueueAttributes"],"Resource":"'$QUEUE_ARN'"}]
  }'

# Event source mapping
aws lambda create-event-source-mapping --function-name hello \
  --event-source-arn $QUEUE_ARN \
  --batch-size 10 \
  --maximum-batching-window-in-seconds 5
```

Mande mensagens na SQS e veja Lambda processar (CloudWatch Logs).

### 🧪 Lab 8.6 — ALB + ECS service

```bash
# Target group
TG_ARN=$(aws elbv2 create-target-group --name hello-tg \
  --protocol HTTP --port 80 --vpc-id $VPC_ID \
  --target-type ip --health-check-path / \
  --query 'TargetGroups[0].TargetGroupArn' --output text)

# Security group ALB
SG_ALB=$(aws ec2 create-security-group --group-name sg-alb --description "ALB" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_ALB --protocol tcp --port 80 --cidr 0.0.0.0/0
# SG_APP permite vir do SG_ALB
aws ec2 authorize-security-group-ingress --group-id $SG_APP --protocol tcp --port 80 --source-group $SG_ALB

# ALB
ALB_ARN=$(aws elbv2 create-load-balancer --name streaming-alb \
  --subnets $PUB_A $PUB_B --security-groups $SG_ALB \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Listener HTTPS (precisa de cert ACM)
aws elbv2 create-listener --load-balancer-arn $ALB_ARN \
  --protocol HTTPS --port 443 --certificates CertificateArn=$CERT_ARN \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN
```

---

## 4. Quando usar o quê (decision matrix)

| Caso | Escolha | Por quê |
|------|---------|---------|
| API HTTP típica, baixo a médio tráfego | Lambda + API Gateway HTTP API | Sem servidor pra cuidar, paga só pelo uso |
| API HTTP de alto tráfego constante (24/7) | ECS Fargate + ALB | Custo Lambda em alta volumetria fica > Fargate |
| Worker batch de 10 min processando vídeo | EC2 GPU Spot | Lambda timeout = 15min e sem GPU; ECS sem GPU em Fargate |
| Reagir a evento S3/SQS instantâneo | Lambda | Trigger nativo, sem operação |
| Aplicação NestJS SSR | ECS Fargate (recomendado) | Container, escala, sem patching |
| Job recorrente cron | EventBridge Scheduler → Lambda | Sem servidor parado |
| Migração de app monolito ressacalado | EC2 + ASG | Lift & shift, sem dockerização ainda |

> ⚠️ Fargate **não suporta GPU**. Se você precisa de GPU containerizado, use **ECS no EC2** com instâncias GPU ou EC2 cru.

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| `t3.micro` sem créditos burst | App lenta no pico | `unlimited` mode (paga extra) ou família `m` |
| AMI desatualizada | CVE crítica em prod | Rebuild AMI mensal via pipeline |
| Lambda chamando RDS sem proxy | Conexões esgotadas | RDS Proxy ou cache DB |
| ECS sem health check no ALB | Deploy quebrado não detectado | Sempre health check + grace period |
| Spot crítico sem fallback | Worker derrubado em horário ruim | Mistura de On-Demand + Spot via capacity providers |
| Lambda com pacote de 250 MB | Cold start lento | Container image + slim |
| API Gateway REST quando bastava HTTP | 3.5x mais caro | HTTP API por padrão |
| EC2 com EBS `gp2` legado | Mais caro, menos performance | Migrar para `gp3` |
| Sem auto-shutdown em dev | EC2 ligada fim de semana inteiro | Lambda + EventBridge para stop noturno |

**Custos típicos:**
- `t3.micro`: ~US$ 7.5/mês.
- `g4dn.xlarge` On-Demand: US$ 0.526/h (~US$ 380/mês 24×7) → Spot ~US$ 0.16/h.
- ECS Fargate 256 CPU + 512 MB 24/7: ~US$ 9/mês.
- Lambda 1M reqs + 200ms × 512 MB: ~US$ 1.85/mês (passou do free tier).
- ALB: US$ 16–25/mês baseline.

---

## 6. Checklist de domínio

- [ ] Sei a diferença entre EC2, Fargate, EKS e Lambda e quando usar cada um.
- [ ] Subi EC2 acessível via SSM (sem SSH).
- [ ] Sei quando usar família `g` (Graviton ARM) para economizar.
- [ ] Identifico um workload candidato a Spot (encoding, batch).
- [ ] Subi um container em ECS Fargate atrás de ALB.
- [ ] Subi Lambda com API Gateway HTTP API.
- [ ] Subi Lambda consumindo SQS via event source mapping.
- [ ] Sei o custo aproximado de Lambda × Fargate × EC2 para mesmo workload.
- [ ] Ativei IMDSv2 (`HttpTokens=required`).
- [ ] Aplicação não usa internet via NAT GW desnecessariamente (VPC endpoints).

---

## 7. Recursos

**Oficiais:**
- [EC2 User Guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/)
- [ECS Developer Guide](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/)
- [Lambda Developer Guide](https://docs.aws.amazon.com/lambda/latest/dg/)
- [API Gateway Developer Guide](https://docs.aws.amazon.com/apigateway/latest/developerguide/)
- [AWS Compute Optimizer](https://aws.amazon.com/compute-optimizer/) — recomendações automáticas.

**Posts:**
- "Operating Lambda" — série da AWS (Yan Cui-quality).
- "ECS task lifecycle deep dive" — re:Invent.
- "Spot instance best practices" — AWS Compute Blog.

**Ferramentas:**
- `ec2-instance-selector` — CLI para escolher tipo de instância por critério.
- `lambda-power-tuning` — tune memory pra menor custo.
- `editor` (AWS) — abstração para subir ECS rapidamente.

---

➡️ Próximo: **Módulo 09 — Hosting de aplicação NestJS (SSR)**.
