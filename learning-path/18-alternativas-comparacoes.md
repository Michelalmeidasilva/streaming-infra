# Módulo 18 — Alternativas e Comparações

> **Meta do módulo:** entender quais decisões arquiteturais tomamos no projeto e por quê, conhecer as principais alternativas de cada peça, e saber quando migrar para outra solução conforme o produto cresce.

**Pré-requisitos:** todos os módulos anteriores (você precisa conhecer o que está sendo comparado).

---

## 1. Como ler este módulo

Para cada componente do stack, apresentamos:

1. **O que escolhemos** e a motivação.
2. **As alternativas** com prós/contras.
3. **Quando mudar** — sinais de que a escolha atual virou limitação.

A premissa é **sem solução universalmente certa** — tudo depende de volume, equipe, orçamento e fase do produto.

---

## 2. Compute: ECS Fargate vs alternativas

### Nossa escolha: ECS Fargate (NestJS app)

Sem gerenciar OS, billing por vCPU+RAM, integra com ALB nativamente.

### Alternativas

#### EKS (Kubernetes gerenciado)

| | ECS Fargate | EKS |
|---|------------|-----|
| Curva de aprendizado | Baixa | Alta (Kubernetes é complexo) |
| Ecosystem | AWS-específico | Multi-cloud, enorme |
| Custo base | ~US$ 0 (sem control plane) | US$ 0.10/h por cluster (~US$ 72/mês) |
| Portabilidade | Baixa (ECS proprietary) | Alta (deploy em qualquer K8s) |
| Features avançadas | Limitadas | Helm, Istio, Argo, KEDA, etc. |
| Operação | Simples | Complexa (etcd, addons, upgrades) |

**Quando migrar para EKS:** equipe já sabe K8s, multi-cloud é requisito, precisa de features como KEDA (event-driven autoscaling) ou service mesh (Istio).

#### App Runner

Ainda mais simples que Fargate: você aponta para um repositório ECR ou GitHub, AWS cuida de tudo.

| | ECS Fargate | App Runner |
|---|------------|-----------|
| Controle de rede | Pleno (VPC) | Limitado |
| Custo | Menor em alto uso | Menor em baixo uso (pay-per-request-like) |
| VPC privada | Sim | Sim (mas limitado) |
| Scaling | Granular | Simples |

**Quando usar App Runner:** MVP / protótipo / microserviço simples sem requisitos de VPC complexos.

#### EC2 puro com Auto Scaling

| | ECS Fargate | EC2 + ASG |
|---|------------|-----------|
| Patching OS | AWS | Você |
| GPU | Não | Sim |
| Controle total | Não | Sim |
| Tempo de scale-out | 30–60s | 2–5 min |
| Custo com uso constante | Mais caro | Mais barato |

**Quando usar EC2 puro:** encoding (GPU, já escolhemos), apps com acesso a hardware específico, workload 24/7 constante onde instância reservada + patching vale a pena.

#### Serverless (Lambda + API GW)

| | ECS Fargate | Lambda |
|---|------------|--------|
| Cold start | Não tem | 100–500ms |
| Timeout | Indefinido | 15 min |
| Estado em memória | Sim (request scope) | Não (entre invocações) |
| Custo < 1M reqs/mês | Fixo (caro se idle) | Muito barato |
| Custo > 100M reqs/mês | Barato | Pode ser mais caro |
| NestJS completo | Perfeito | Funciona com `@nestjs/platform-fastify` + adapter |

**Quando usar Lambda para o NestJS:** microserviços pequenos e esporádicos (webhooks, triggers). Para o app principal com SSR e tráfego constante, ECS Fargate ganha.

---

## 3. Banco de dados: RDS Postgres vs alternativas

### Nossa escolha: RDS Postgres

SQL maduro, transações ACID, queries relacionais complexas (billing, usuários, jobs).

### Alternativas

#### Aurora PostgreSQL

| | RDS Postgres | Aurora Postgres |
|---|-------------|----------------|
| Failover | ~60-120s | ~30s |
| Read replicas | Até 5, assíncrono | Até 15, sub-segundo lag |
| Storage | Provisionado (max 64 TB) | Auto-grow, até 128 TB |
| Custo | Menor para instâncias pequenas | 20% mais caro por instância, storage mais caro |
| Performance | Boa | Até 5× vs MySQL, 3× vs Postgres standard |
| Serverless v2 | Não | Sim |

**Quando migrar para Aurora:** volume alto de leituras, precisa de Serverless v2, banco > 10 TB, SLA de failover < 30s.

#### PlanetScale (MySQL serverless)

Banco MySQL distribuído com branching de schema (como Git para banco). Não-AWS.

**Quando usar:** equipe familiarizada com MySQL, precisa de deploy de schema sem downtime facilitado, workload principalmente web.

#### Neon (Postgres serverless)

Postgres serverless com scale-to-zero e branching.

**Quando usar:** dev/staging (custo zero quando idle), times pequenos sem DevOps para cuidar de RDS.

#### CockroachDB / TiDB

Postgres-compatible, distribuído globalmente, escala horizontal de escrita.

**Quando usar:** necessidade de escrita distribuída multi-região com consistência forte. Complexidade e custo altos — só para escala global real.

#### SQLite + LiteFS / Turso

Interessante para apps pequenos, edge computing. Não adequado para nosso stack.

---

## 4. NoSQL: DynamoDB vs alternativas

### Nossa escolha: DynamoDB

Latência consistente sub-10ms, escala ilimitada, integração nativa AWS.

### Alternativas

#### MongoDB Atlas

| | DynamoDB | MongoDB Atlas |
|---|---------|--------------|
| Query model | Chave/valor + queries indexadas | BSON + aggregation pipeline rico |
| Joins | Não nativos | `$lookup` (limitado) |
| Schema | Livre | Livre (mas com validação opcional) |
| Custo | Pay-per-request ou provisioned | US$ 57/mês mínimo (M10) |
| Multi-region | Global Tables (caro) | Atlas Global Clusters |
| Integração AWS | Nativa | Via driver, sem IAM nativo |

**Quando usar MongoDB:** queries complexas de documento, equipe com expertise MongoDB, sem necessidade de integração AWS nativa profunda.

#### Redis como datastore primário

| | DynamoDB | Redis (ElastiCache) |
|---|---------|---------------------|
| Persistência | Forte | Opcional (RDB/AOF) |
| Tamanho | Ilimitado | Limitado pela RAM |
| Custo por GB | Barato | Caro (RAM > SSD) |
| Latência | < 10ms | < 1ms |

**Quando usar Redis como primário:** dados que precisam de < 1ms e cabem em memória (rate limiting, sessões, leaderboards). **Não substitui DynamoDB** para dados de negócio.

#### FaunaDB / Upstash

Edge-first, pay-per-request. Para apps serverless que precisam de DB globalmente.

#### OpenSearch (para catálogo com busca)

Quando DynamoDB não basta para full-text search:

```
DynamoDB (fonte de verdade) → DynamoDB Stream → Lambda → OpenSearch
```

Query em OpenSearch (full-text, fuzzy, filtros compostos), resultado com IDs volta para DynamoDB para buscar dados completos.

**Quando adicionar:** quando usuários reclamam que busca no catálogo é ruim. OpenSearch = custo de US$ 150–300/mês para 3 nós.

---

## 5. Cache: ElastiCache Redis vs alternativas

### Nossa escolha: ElastiCache Redis

Gerenciado, suporte a estruturas ricas, pub/sub, persistência opcional.

### Alternativas

#### Upstash Redis

Redis serverless, pay-per-request. Zero instâncias.

| | ElastiCache Redis | Upstash |
|---|-----------------|---------|
| Custo baseline | US$ 25/mês (t4g.micro × 2) | US$ 0 (free tier 10k reqs/dia) |
| Custo alto volume | Instância fixa | US$ 0.2/100k reqs |
| Latência | < 1ms (mesma VPC) | 5–10ms (HTTP API) |
| Features | Tudo do Redis | Maioria do Redis |
| Multi-AZ | Sim | Sim (global) |

**Quando usar Upstash:** dev/staging, apps serverless, carga imprevisível baixa. Break-even em ~50M reqs/mês com ElastiCache t4g.micro.

#### Momento Cache

Cache serverless sem preocupação com tamanho ou nós. API simples.

**Quando usar:** cache de lookups simples, times sem expertise em Redis.

#### DynamoDB Accelerator (DAX)

Cache em memória específico para DynamoDB. Latência de microsegundos.

| | ElastiCache Redis | DAX |
|---|-----------------|-----|
| Para | Qualquer coisa | Só DynamoDB |
| Latência | < 1ms | < 100μs |
| API | Redis | DynamoDB idêntica (drop-in) |
| Custo | US$ 25/mês (t4g.micro) | US$ 40/mês mínimo |

**Quando usar DAX:** app usa DynamoDB intensamente, quer drop-in sem mudar código, aceita pagar mais.

#### Redis em EC2 self-managed

| | ElastiCache | EC2 self-managed |
|---|------------|-----------------|
| Patching | AWS | Você |
| Failover | Automático | Manual ou Sentinel/Cluster |
| Custo | +30% vs EC2 equivalente | Menor |

**Quando usar:** economizar US$ 20–30/mês vale o overhead operacional? Quase nunca.

---

## 6. Mensageria: SQS/SNS/EventBridge vs alternativas

### Nossa escolha: SQS + SNS + EventBridge

Gerenciados, integração nativa, custo baixo, sem infra.

### Alternativas

#### Amazon MQ / RabbitMQ

| | SQS | Amazon MQ RabbitMQ |
|---|-----|-------------------|
| Custo | US$ 0.40/M msgs | US$ 220/mês (cluster 3 nós) |
| Protocolo | AWS SDK | AMQP, MQTT, STOMP |
| Routing avançado | Limitado (filter policy) | Fanout/topic/direct/headers exchanges |
| Acknowledge manual | Visibility timeout | ACK nativo |
| Quando migrar | Nunca (se começando do zero) | Migração de app legado |

#### Apache Kafka / Amazon MSK

| | SQS | Kafka (MSK) |
|---|-----|------------|
| Modelo | Queue (consume e deleta) | Log (consume sem deletar, replay) |
| Retenção | 4 dias (max 14) | Indefinida |
| Ordering | FIFO opcional | Partition-level |
| Consumers | 1 consumer por mensagem | Múltiplos consumer groups |
| Custo | US$ 0.40/M msgs | US$ 0.21/h por broker (~US$ 450/mês para 3 brokers) |
| Escala | Ilimitada | Alta (mas operação complexa |

**Quando usar Kafka:** você precisa de replay (auditoria, event sourcing), múltiplos consumer groups independentes no mesmo evento, throughput de M msgs/s. Para streaming de vídeo só, SQS suficiente. Para analytics de eventos do player em tempo real, Kafka faz sentido.

#### Google Pub/Sub / Azure Service Bus

Equivalentes gerenciados de outros clouds. Só se for multi-cloud.

#### Confluent Cloud / Upstash Kafka

Kafka serverless. Paga por throughput, sem brokers. Custo menor que MSK para cargas baixas.

---

## 7. Encoding: EC2 GPU vs alternativas

### Nossa escolha: EC2 GPU Spot (g4dn) + FFmpeg NVENC

Máximo controle, mínimo custo unitário, escala para zero.

### Alternativas

#### AWS Elemental MediaConvert

| | EC2 GPU + FFmpeg | MediaConvert |
|---|----------------|-------------|
| Custo / min 1080p | ~US$ 0.002 (Spot) | US$ 0.0075 |
| Custo / min 4K | ~US$ 0.005 (Spot) | US$ 0.0195 |
| DRM nativo | Não | Sim (SPEKE) |
| Controle codecs/filtros | Total | Templates |
| Gerenciamento | Você (ASG, AMI, worker) | Zero |
| Latência do job | Imediata (se worker pronto) | Filas compartilhadas (min a horas) |
| SLA | Você | AWS (99.9%) |

**Quando migrar para MediaConvert:** necessidade de DRM (Widevine/FairPlay) nativo, equipe sem DevOps para manter workers, volume < 1000 horas/mês (custo extra ainda aceitável), conformidade exige SLA provedor.

#### AWS Elemental MediaPackage

Empacotamento e origem para streaming (HLS/DASH/CMAF). Complementa MediaConvert.

**Quando usar:** live streaming, DRM com SPEKE, necessidade de time-shifted viewing (DVR).

#### FFmpeg em Lambda (serverless)

Lambda layer com FFmpeg compilado. Timeout = 15 min, sem GPU.

| | EC2 GPU | Lambda + FFmpeg |
|---|---------|----------------|
| GPU | Sim | Não |
| Timeout | Ilimitado | 15 min |
| Custo por job 10min | ~US$ 0.027 Spot | US$ 0.002 (3GB RAM) |
| Manutenção | AMI, ASG | Layer, deploy |

**Quando usar Lambda para encoding:** vídeos curtos (< 5 min), thumbnails, processamento leve (resize, watermark). Não substitui GPU para 1080p/4K.

#### Mux / Cloudflare Stream / Bunny Stream

SaaS de encoding e CDN de vídeo. Você manda o vídeo, eles transcodam e entregam.

| | Stack DIY | Mux / Cloudflare |
|---|-----------|-----------------|
| Custo encoding | ~US$ 0.002/min | US$ 0.015/min (Mux) |
| CDN entrega | ~US$ 0.085/GB | Incluído (~US$ 0.01–0.02/min armazenado) |
| DRM | DIY | Incluído |
| Player analytics | DIY | Incluído |
| Controle | Total | Limitado à API |
| Operação | Você | Zero |

**Quando usar Mux/Cloudflare:** equipe pequena sem infra dedicada, MVP rápido, você paga pelo conviênencia e aceita o custo maior.

#### Coconut.co / Transloadit

SaaS de encoding especializado. Cobra por minuto encodado.

---

## 8. CDN: CloudFront vs alternativas

### Nossa escolha: CloudFront

Integração nativa com S3, ALB, Lambda@Edge, OAC, WAF. 600+ PoPs.

### Alternativas

#### Cloudflare CDN

| | CloudFront | Cloudflare |
|---|-----------|-----------|
| Egress | US$ 0.085/GB (Americas) | US$ 0 (egress grátis!) |
| PoPs | ~600 | ~310 |
| Integração AWS | Nativa | Via origin pull |
| WAF | US$ 5/WebACL + regras | Incluído no plano |
| Workers (edge fn) | Lambda@Edge / CF Functions | Workers (mais flexíveis, mais barato) |
| Cache rules | Behaviors + policies | Page rules / Cache rules |
| Preço plano Pro | US$ 0/mês + por uso | US$ 20/mês fixo + por uso |

**Quando usar Cloudflare:** projetos que trafegam muitos TBs e o egress CloudFront virou parte relevante da fatura. Egress grátis no Cloudflare é o diferencial principal.

> 💡 Estratégia comum: CloudFront para S3 + APIs AWS (integração nativa), Cloudflare para edge de vídeo público de alto volume.

#### Fastly

CDN programável com VCL (Varnish Configuration Language). Mais controle que CloudFront, curva íngreme.

**Quando usar:** controle fino de cache behavior, streaming de alto volume com time-to-first-byte crítico.

#### BunnyCDN

CDN mais barata do mercado. US$ 0.01/GB na maioria das regiões.

| | CloudFront (10 TB) | BunnyCDN (10 TB) |
|---|------------------|----------------|
| Custo egress | ~US$ 850/mês | ~US$ 100/mês |
| Integração AWS | Nativa | Via origin pull |
| Features | WAF, OAC, Lambda@Edge | Mais simples |

**Quando usar:** plataforma com muitos TBs de vídeo e sem necessidade de Lambda@Edge. Economiza 85%+ de egress.

---

## 9. Autenticação: o que não está no stack (mas precisa)

Não incluímos auth no projeto base. Opções:

| Solução | Custo | Quando |
|---------|-------|--------|
| **Cognito User Pools** | Grátis até 50k MAUs | App AWS-first, OAuth2 simples |
| **Auth0** | Grátis até 7.5k MAUs, US$ 23/mês depois | Mais features, menor vendor lock |
| **Clerk** | Grátis até 10k MAUs | UI pronta, React/Next integrado |
| **Supabase Auth** | Grátis até 50k MAUs | Postgres nativo, open source |
| **Custom JWT** | Custo de desenvolvimento | Controle total, sem vendor |

**Recomendação:** Cognito para stack 100% AWS (integra com API GW, ALB, CloudFront); Auth0/Clerk para melhor DX e features (social login, MFA, organizations).

---

## 10. IaC: Terraform vs alternativas

### Nossa escolha: Terraform (HCL)

Maior ecossistema, multi-cloud, registry de módulos.

### Alternativas

#### CDK (Cloud Development Kit)

| | Terraform | CDK |
|---|-----------|-----|
| Linguagem | HCL (declarativo) | TypeScript/Python/Java (imperativo) |
| State | S3 (você gerencia) | CloudFormation (AWS gerencia) |
| Multi-cloud | ✅ | ❌ (AWS only) |
| Abstração | Módulos | Constructs (L1/L2/L3) |
| Debugging | Plano textual | Stack traces reais |
| Equipe DevOps | Natural | Preferem código real |
| Ekossistema | Enorme | Grande |

**Quando usar CDK:** equipe prefere TypeScript/Python, AWS only, quer abstrações de alto nível (L3 constructs que criam patterns inteiros).

#### Pulumi

Como CDK mas multi-cloud. TypeScript/Python/Go. State plugável.

**Quando usar:** multi-cloud com código real, equipe que odeia HCL.

#### CloudFormation

YAML/JSON nativo AWS. Sem custo, integrado com Control Tower, StackSets.

**Quando usar:** organização que já usa CloudFormation com StackSets, compliance exige auditoria AWS-native.

#### OpenTofu

Fork open-source do Terraform pós licença BSL. Drop-in replacement.

**Quando usar:** preocupação com licença HashiCorp (BSL), mesma sintaxe HCL, sem mudanças de código.

---

## 11. CI/CD: GitHub Actions vs alternativas

### Nossa escolha: GitHub Actions

Ecossistema, OIDC AWS nativo, grátis para repos públicos.

### Alternativas

| Ferramenta | Custo | Quando |
|-----------|-------|--------|
| **GitLab CI** | Grátis até 400 min/mês | Equipe usa GitLab, features completas |
| **CodePipeline + CodeBuild** | US$ 1/pipeline/mês + build | Stack 100% AWS, sem GitHub |
| **CircleCI** | Grátis 6k min/mês | Performance, paralelismo avançado |
| **Buildkite** | US$ 25/mês + agents | Self-hosted, sem limite de uso |
| **Dagger** | Aberto | Pipelines portáveis entre CI providers |

**Quando usar CodePipeline:** compliance exige que builds sejam dentro da AWS (dados não saem para GitHub servers), integração com CodeCommit + CodeDeploy nativamente.

---

## 12. Observabilidade: CloudWatch vs alternativas

### Nossa escolha: CloudWatch + X-Ray

Integração nativa, sem agente extra, grátis para métricas padrão AWS.

### Alternativas

#### Datadog

| | CloudWatch | Datadog |
|---|-----------|---------|
| Custo | Variável por uso | US$ 15–23/host/mês |
| UX | Funcional | Superior |
| APM | X-Ray (básico) | APM completo + profiling |
| Alertas | Alarms (suficiente) | Mais rico + On-Call management |
| Logs | Logs Insights | Log Management avançado |
| Tracing | X-Ray | Trace distribuído completo |

**Quando usar Datadog:** equipe > 5 devs, produto em produção com SLA, necessidade de on-call management e alertas ricos. Custo alto mas economiza tempo de dev significativo.

#### Grafana + Prometheus (self-hosted ou Grafana Cloud)

Open source. Muito poderoso. Requer mais operação.

**Quando usar:** equipe com expertise DevOps, quer dashboards customizados, custo de Datadog não justificado.

#### Honeycomb

Observabilidade baseada em eventos. Superior ao CloudWatch para debugging de produção.

**Quando usar:** produto maduro com problemas de debug em produção, equipe SRE.

#### New Relic

Similar ao Datadog. Free tier generoso (100 GB logs/mês grátis).

---

## 13. Mapa de decisão: "Quando mudar?"

| Sinal | Ação |
|-------|------|
| CloudFront egress > US$ 1.000/mês | Avaliar Cloudflare para vídeo |
| RDS > 80% CPU consistentemente | Aurora + read replicas ou Serverless v2 |
| Lambda cold start > 500ms incomoda usuário | Provisioned concurrency ou migrar para ECS |
| Encoding jobs > 500h/mês | Negociar preço com AWS ou avaliar MediaConvert |
| DynamoDB hot partition recorrente | Revisão de modelo single-table |
| ECS + K8s features sendo "workaround" | Migrar para EKS |
| Encoding em CPU para thumbnails | Lambda + FFmpeg (sem GPU necessário) |
| Auth própria virando problema | Cognito ou Auth0 |
| CloudWatch não responde perguntas de debug | Adicionar Datadog ou Honeycomb |
| Terraform plan > 5 min | Modularização + state particionado |

---

## 14. Tabela geral: stack atual vs alternativas por fase

| Fase | Componente | Stack atual | Alternativa de escala |
|------|-----------|-------------|----------------------|
| MVP | App | ECS Fargate | App Runner (mais simples) |
| MVP | Banco | RDS Postgres | Neon/PlanetScale (serverless) |
| MVP | Cache | ElastiCache | Upstash (serverless) |
| Beta | CDN | CloudFront | + BunnyCDN para vídeo de alto volume |
| Beta | Encoding | EC2 GPU Spot | + MediaConvert para DRM |
| Prod | DB scale | RDS | Aurora Serverless v2 |
| Prod | Obs | CloudWatch | + Datadog ou Grafana Cloud |
| Escala | K8s | ECS | EKS com KEDA |
| Escala | Events | SQS/EventBridge | + Kafka (MSK) para replay |
| Escala | Auth | Cognito / Custom | Auth0 com organizations |
| Escala | CDN | CloudFront | Cloudflare para egress alto |

---

## 15. Checklist de domínio

- [ ] Sei explicar por que escolhemos ECS Fargate em vez de EKS ou Lambda para o NestJS.
- [ ] Sei quando MediaConvert vale mais que EC2 GPU próprio.
- [ ] Entendo a diferença de custo de egress entre CloudFront e Cloudflare.
- [ ] Sei a diferença entre SQS e Kafka e quando cada um é adequado.
- [ ] Conheço alternativas ao DynamoDB e quando MongoDB ou OpenSearch se justifica.
- [ ] Entendo os trade-offs de Terraform vs CDK.
- [ ] Sei quando adicionar Datadog ao stack sem abandonar CloudWatch.
- [ ] Consigo explicar para um stakeholder por que a stack atual foi escolhida.
- [ ] Tenho um plano de migração claro para os principais componentes quando o volume crescer.

---

## 16. Recursos

**Comparações:**
- [AWS vs Alternatives](https://banzaicloud.com/blog/kubernetes-cost-optimization/) — análise de custo.
- [cloudoptimizer.io](https://cloudoptimizer.io) — comparação de preços.
- [inframap.earthly.dev](https://earthly.dev/blog/aws-cost-optimization/) — guia de otimização.

**Alternativas específicas:**
- [Upstash docs](https://upstash.com/docs/redis)
- [Mux docs](https://docs.mux.com/)
- [Cloudflare Stream](https://developers.cloudflare.com/stream/)
- [BunnyCDN](https://bunny.net/pricing/)
- [Neon docs](https://neon.tech/docs)

**Decisão arquitetural:**
- _Building Microservices_ — Sam Newman (O'Reilly).
- _Fundamentals of Software Architecture_ — Mark Richards & Neal Ford.
- AWS re:Invent "Choosing the right database" — série anual.
