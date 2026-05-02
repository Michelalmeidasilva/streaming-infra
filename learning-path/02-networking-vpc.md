# Módulo 02 — Networking & VPC

> **Meta do módulo:** entender e construir a fundação de rede onde todo o resto vai morar — VPCs, subnets, rotas, segurança de borda, DNS.

**Pré-requisitos:** módulo 01.

---

## 1. Conceitos

### 1.1 O que é uma VPC

**VPC (Virtual Private Cloud)** = rede privada virtual, isolada por padrão, dentro de uma região AWS. É o equivalente em cloud ao **rack/datacenter próprio**: você decide o range de IPs, quem entra, quem sai e como.

Toda região nova da AWS já vem com uma "default VPC" pronta, mas você **vai criar a sua** porque a default tem CIDR genérico (`172.31.0.0/16`) e configurações que não casam com produção.

> 🧠 **Modelo mental:** VPC é como um condomínio fechado. Você define o terreno (CIDR), divide em quadras (subnets), constrói portarias (gateways) e define regras de quem pode entrar em cada quadra (security groups, NACLs).

### 1.2 CIDR — endereçamento IP

CIDR (Classless Inter-Domain Routing) é o jeito de descrever um range de IPs com **base + tamanho**:

- `10.0.0.0/16` → 65.536 IPs (`10.0.0.0` a `10.0.255.255`).
- `10.0.1.0/24` → 256 IPs (`10.0.1.0` a `10.0.1.255`).
- `10.0.1.0/28` → 16 IPs.

A AWS aceita VPC com prefixos de `/16` (max) a `/28` (min). Use ranges privados: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`.

> 💡 **Boa prática:** use **`10.x.0.0/16`** por VPC, deixando bastante espaço para crescer. Evite `172.x` (conflita com Docker) e `192.168.x` (conflita com Wi-Fi doméstico, dificulta VPN).

**Em cada subnet, a AWS reserva 5 IPs**: o primeiro (`.0`), o último (`.255`), e três no início (`.1`, `.2`, `.3`). Conta-os ao planejar.

### 1.3 Subnets

Subnet = sub-rede dentro da VPC, **vive em uma única AZ**. Ela é "pública" ou "privada" pelo seu **route table**:

- **Subnet pública** = tem rota `0.0.0.0/0` para um **Internet Gateway**.
- **Subnet privada** = não tem rota direta para internet; pode ter rota para um **NAT Gateway** se precisar fazer chamadas saindo.
- **Isolated subnet** = sem rota para internet em nenhum sentido (banco de dados, ambientes regulados).

> **Padrão clássico para apps web/streaming:**
> - 2–3 AZs para alta disponibilidade.
> - 3 tipos de subnet por AZ: `public`, `private-app`, `private-data`.
> - Total: 6–9 subnets.

### 1.4 Route Tables

Tabela de rotas associada a uma ou mais subnets. Cada rota é um par `destino-CIDR → target`.

Exemplos de targets:
- `local` (sempre presente, dentro da VPC).
- **Internet Gateway (IGW)** — saída para internet em ambos sentidos.
- **NAT Gateway (NATGW)** — saída para internet só de dentro pra fora (resposta volta).
- **VPC Peering / Transit Gateway** — outra VPC.
- **VPC Endpoint** — serviço AWS sem passar pela internet.

### 1.5 Internet Gateway vs NAT Gateway

| | Internet Gateway | NAT Gateway |
|---|------------------|-------------|
| Direção | Bidirecional | Saída-only |
| Usado por | Subnets públicas | Subnets privadas |
| Custo | Grátis (pago no egress) | ~US$ 32/mês + US$ 0.045/GB processado |
| Quantos por VPC | 1 | 1 por AZ (recomendado) |
| Substituível por | nada | NAT instance EC2 |

> ⚠️ **Cuidado:** NAT GW é caro. Para laboratório, opções mais econômicas:
> - Use só subnets públicas controladas por SG.
> - Use **NAT instance** (`t4g.nano` ~ US$ 3/mês).
> - Use **VPC endpoints** para serviços AWS (S3, DynamoDB têm endpoints **grátis**).

### 1.6 Security Groups (SG)

Firewall **stateful** anexado a recursos (EC2, RDS, ELB, Lambda em VPC). Regras:

- Apenas **allow** (não tem deny).
- Stateful: se uma conexão é permitida saindo, a resposta volta automaticamente.
- Pode referenciar **outro SG** como source/destination (super útil: "tudo que está no SG `sg-app` pode falar com `sg-db`").

> 💡 **Dica:** sempre referencie SGs em vez de CIDRs internos. Evita o problema de "atualizar lista de IPs quando criar nova instância".

### 1.7 Network ACLs (NACL)

Firewall **stateless** no nível da subnet. Permite **deny explícito**. Regras numeradas (avaliadas em ordem). Stateless = você precisa permitir tráfego nos dois sentidos manualmente.

**Quando usar NACL?** Praticamente nunca para o caso do dia-a-dia. Use SG. NACL é para casos como "bloquear um IP malicioso na VPC inteira" ou compliance específico.

### 1.8 VPC Endpoints

Permitem chamar serviços AWS **sem sair da VPC para a internet**. Dois tipos:

- **Gateway endpoint** — para S3 e DynamoDB. **Grátis**. Modificam route table.
- **Interface endpoint (PrivateLink)** — para a maioria dos outros serviços (SQS, Secrets Manager, KMS, etc). ~US$ 7/mês por endpoint + US$ 0.01/GB.

> 💡 **Por que importa?** Sem endpoint, uma Lambda em subnet privada chamando S3 vai pelo NAT GW (US$ 0.045/GB). Com gateway endpoint, vai direto e grátis. **Em produção, cria gateway endpoint para S3 e DynamoDB sempre.**

### 1.9 DNS na AWS

- **Route53** — DNS gerenciado da AWS. Zonas públicas (internet) e privadas (dentro de VPC).
- **DNS interno automático** — toda VPC tem DNS interno (ex: `ip-10-0-1-23.ec2.internal`).
- **Resolver** — Route53 Resolver permite forward de queries entre on-prem e AWS.
- **ACM (Certificate Manager)** — emite certificados TLS grátis para domínios em Route53.

### 1.10 Load Balancers (visão de rede)

A AWS oferece três tipos (mais detalhe no módulo 13):

| LB | Camada | Quando |
|----|--------|--------|
| **ALB** (Application LB) | L7 (HTTP/HTTPS) | APIs, microsserviços, path-based routing |
| **NLB** (Network LB) | L4 (TCP/UDP) | Performance extrema, IPs estáticos, protocolos não-HTTP |
| **CLB** (Classic, legado) | L4/L7 | Não use em projeto novo |

---

## 2. Por que isso importa no streaming

Em uma plataforma de streaming você tem múltiplos planos de rede:

1. **Plano de controle** (APIs do app: catálogo, autenticação, faturamento) → ALB + private app subnets.
2. **Plano de dados** (vídeo) → CloudFront → S3, **fora da sua VPC**. Você não paga egress da sua VPC para CloudFront.
3. **Plano de processamento** (encoders, jobs batch) → subnets privadas, podem precisar de saída controlada.
4. **Plano de dados sensíveis** (RDS, Redis) → subnets isoladas, sem internet.

Sem entender VPC, você cai em armadilhas como: "minha Lambda chama S3 via NAT GW pagando US$ 0.045/GB e nunca percebi que tinha endpoint grátis disponível". Em projeto com vídeo (GBs/TB), isso é a diferença de US$ 100 vs US$ 1000+ na fatura.

---

## 3. Laboratório prático

### 🧪 Lab 2.1 — Anatomia da default VPC

```bash
$ aws ec2 describe-vpcs --filters Name=is-default,Values=true \
    --profile streaming-admin --region us-east-1

$ aws ec2 describe-subnets \
    --filters Name=vpc-id,Values=<vpc-id-default> \
    --profile streaming-admin
```

Observe: 1 VPC, ~3 subnets (uma por AZ), todas públicas, com IGW associado.

### 🧪 Lab 2.2 — Criar uma VPC do zero (Console)

1. **VPC → Create VPC**.
2. Selecione **VPC and more** (cria tudo de uma vez).
3. Configurações:
   - Name: `streaming-vpc`
   - IPv4 CIDR: `10.0.0.0/16`
   - Number of AZs: **2**
   - Public subnets: 2
   - Private subnets: 2
   - NAT gateways: **None** (laboratório!) ou **1 in 1 AZ** se for fazer testes de saída
   - VPC endpoints: **S3 Gateway**
   - DNS hostnames: ☑
   - DNS resolution: ☑
4. Clique em **Create VPC**.
5. Tag tudo com `Project=streaming-learning, Environment=lab`.

> Se escolher 1 NAT GW, **destrua a VPC ao final do dia** (US$ 1+/dia se deixar).

### 🧪 Lab 2.3 — Criar a mesma VPC via CLI (sem o wizard)

```bash
# 1. VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=streaming-vpc-cli},{Key=Project,Value=streaming-learning}]' \
  --query 'Vpc.VpcId' --output text)
echo $VPC_ID

# 2. Habilita DNS hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# 3. Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --vpc-id $VPC_ID --internet-gateway-id $IGW_ID

# 4. Subnets públicas
PUB_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
PUB_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)

# 5. Route Table pública
RT_PUB=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $RT_PUB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --subnet-id $PUB_A --route-table-id $RT_PUB
aws ec2 associate-route-table --subnet-id $PUB_B --route-table-id $RT_PUB

# 6. Subnets privadas
PRIV_A=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.11.0/24 --availability-zone us-east-1a --query 'Subnet.SubnetId' --output text)
PRIV_B=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.12.0/24 --availability-zone us-east-1b --query 'Subnet.SubnetId' --output text)

# 7. S3 Gateway Endpoint (grátis e essencial)
aws ec2 create-vpc-endpoint --vpc-id $VPC_ID --service-name com.amazonaws.us-east-1.s3 \
  --route-table-ids $RT_PUB
```

Rodou? Você criou uma VPC inteira via API.

### 🧪 Lab 2.4 — Security Group e teste de conectividade

1. Crie um SG **`sg-public-web`** permitindo `80, 443, 22` de `0.0.0.0/0`.
2. Crie um SG **`sg-app`** permitindo `8080` apenas do `sg-public-web`.
3. Suba 2 EC2 `t3.micro` Amazon Linux:
   - `web` na subnet pública com `sg-public-web` e public IP.
   - `app` na subnet privada com `sg-app`, sem public IP.
4. Conecte via **SSM Session Manager** (não SSH, sem chave!):
   ```bash
   $ aws ssm start-session --target i-xxxxx --profile streaming-admin
   ```
   > Para isso funcionar, a EC2 precisa do role `AmazonSSMManagedInstanceCore`.
5. Da `web`, teste conexão para `app:8080` (`curl 10.0.11.x:8080`). Funciona pois o SG permite.
6. Da internet, teste `app:8080`. Falha — não tem rota.

### 🧪 Lab 2.5 — Route53 e domínio próprio

Se você não tem domínio, compre um (~US$ 12/ano). Recomendados: namecheap, registro.br, ou o próprio Route53.

```bash
# Cria zona pública
aws route53 create-hosted-zone --name streaming.example.com --caller-reference $(date +%s)
```

Adicione os 4 NS records do Route53 no registrar do domínio. Em ~10 minutos o DNS está delegado.

> Vamos usar essa zona em módulos 04 (CloudFront), 09 (frontend) e 10 (streaming).

### 🧪 Lab 2.6 — Limpeza (importante!)

Se criou NAT GW ou EIPs, destrua agora:

```bash
# Lista NAT GWs
aws ec2 describe-nat-gateways --filter Name=state,Values=available

# Deleta
aws ec2 delete-nat-gateway --nat-gateway-id <id>

# Libera EIPs órfãos
aws ec2 describe-addresses --query 'Addresses[?AssociationId==null]'
aws ec2 release-address --allocation-id <id>
```

---

## 4. Armadilhas e custos

| Armadilha | Custo / impacto | Como evitar |
|-----------|-----------------|-------------|
| NAT Gateway esquecido | US$ 32/mês fixo + US$ 0.045/GB | Destruir após lab; usar VPC endpoints; NAT instance |
| EIP alocado e desassociado | US$ 3.6/mês por IP em 2024+ | `release-address` ao destruir EC2 |
| VPC sem S3 Gateway Endpoint | Egress de Lambda/EC2 -> S3 via NAT | Sempre criar Gateway Endpoint S3 e DynamoDB |
| Subnets pequenas demais | "Insufficient IPs" ao escalar | Use `/24` por subnet, total `/16` por VPC |
| AZs concentradas | Outage de AZ derruba tudo | Sempre 2+ AZs |
| Cross-AZ data transfer | US$ 0.01/GB cada sentido | Quando der, mantenha tráfego dentro da AZ |
| Public IP em recurso interno | Surface de ataque + US$/IP | "Auto-assign public IP" desativado em subnet privada |
| SG aberto `0.0.0.0/0` para SSH | Hack em horas | SSM Session Manager dispensa SSH |

---

## 5. Decisões de arquitetura comuns

### "Uma VPC por ambiente" vs "uma VPC com tudo"

Boa prática: **uma VPC por conta-AWS, e uma conta por ambiente** (dev / staging / prod). Use AWS Organizations + IAM Identity Center. Em laboratório, uma VPC só já basta.

### CIDR planning

| Ambiente | CIDR sugerido |
|----------|---------------|
| `dev` | `10.0.0.0/16` |
| `staging` | `10.10.0.0/16` |
| `prod` | `10.20.0.0/16` |
| `shared-services` | `10.30.0.0/16` |

Ranges separados permitem **VPC Peering / Transit Gateway** sem conflito de IP.

### Single-NAT vs NAT-por-AZ

- **Lab/dev:** 1 NAT GW total (ou nenhum). Falha de AZ = saída quebrada — aceitável.
- **Prod:** 1 NAT GW por AZ. Custa 3x mais mas elimina ponto único.

### Public-só vs public+private

Resista à tentação de jogar tudo em subnet pública "para simplificar". A latência é a mesma, mas a superfície de ataque é gigante. Padrão ouro: **só ALB/NAT GW na subnet pública; tudo o mais privado**.

---

## 6. Checklist de domínio

- [ ] Sei desenhar uma VPC multi-AZ no papel sem consultar nada.
- [ ] Sei calcular quantos IPs cabem em `/16`, `/24`, `/28`.
- [ ] Diferencio Security Group (stateful) de NACL (stateless).
- [ ] Sei quando usar Gateway Endpoint vs Interface Endpoint.
- [ ] Sei o custo aproximado mensal de NAT GW e por que é caro.
- [ ] Configurei SSM Session Manager para acessar EC2 sem SSH.
- [ ] Tenho domínio configurado em Route53 com zona pública.
- [ ] Destruí qualquer NAT GW/EIP de teste antes de fechar a sessão.

---

## 7. Recursos

**Oficiais:**
- [Amazon VPC User Guide](https://docs.aws.amazon.com/vpc/latest/userguide/)
- [VPC Pricing](https://aws.amazon.com/vpc/pricing/)
- [Security Groups vs NACLs](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Security.html)

**Vídeos / blogs:**
- AWS re:Invent — "Networking foundations: VPC, hybrid networking, and DNS" (busque a edição mais recente).
- Adrian Cantrill — curso "AWS Certified Solutions Architect Associate" tem o melhor capítulo de VPC pago do mercado.

**Ferramentas:**
- [aws-vpc-visualizer](https://github.com/lucianopf/aws-vpc-visualizer) — desenha sua VPC.
- [hava.io](https://www.hava.io/) — diagramas automáticos de VPC.

---

➡️ Próximo: **Módulo 03 — IAM & Segurança**.
