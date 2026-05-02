# Módulo 05 — Bancos de dados (RDS & DynamoDB)

> **Meta do módulo:** entender quando usar SQL gerenciado (RDS / Aurora) vs NoSQL gerenciado (DynamoDB), modelar dados em cada um, e provisionar com alta disponibilidade e backup decentes.

**Pré-requisitos:** módulos 02, 03.

---

## 1. Conceitos

### 1.1 SQL vs NoSQL: a decisão fundamental

| | SQL (RDS, Aurora) | NoSQL (DynamoDB) |
|---|------------------|------------------|
| Schema | Rígido | Flexível por item |
| Consultas | JOIN, agregações arbitrárias | Acesso por chave + GSI |
| Escala | Vertical + read replicas | Horizontal automática |
| Latência | ms a dezenas de ms | Single-digit ms (consistente) |
| Custo base | Instância 24/7 | Pay-per-request ou capacity |
| Quando | Modelo relacional, relatórios | Acessos previsíveis em alta escala |

**Heurística para streaming:**

- **Catálogo de vídeos / metadados editoriais** → DynamoDB (acesso por `videoId`).
- **Usuários, billing, planos, assinaturas, logs de auditoria** → RDS (Postgres).
- **Sessões de player, watch history** (alto throughput, simples) → DynamoDB.
- **Recomendações** → começa em RDS, vira ML pipeline com S3+SageMaker depois.

### 1.2 RDS — Relational Database Service

**Engines suportados:** MySQL, PostgreSQL, MariaDB, Oracle, SQL Server, e **Aurora** (MySQL/Postgres-compatible, otimizada pela AWS).

#### Aurora vs RDS Postgres

- **Aurora** tem storage distribuído auto-resizing, replicação para 6 storage nodes em 3 AZs, failover em segundos, read replicas baratas.
- **RDS Postgres** é o engine open-source padrão; mais barato em instâncias pequenas; menos features de HA built-in.

> 💡 Comece com **RDS Postgres** em laboratório (`db.t4g.micro`, free tier 12 meses). Migre para Aurora quando for produção real e tiver volume.

#### Conceitos chave RDS

- **DB Instance class** = tamanho da máquina (`db.t4g.micro`, `db.m7g.large`, etc).
- **Storage type** = `gp3` (general purpose, recomendado), `io2` (alta IOPS).
- **Multi-AZ** = standby síncrono em outra AZ. Failover automático ~60-120s. **2x preço.**
- **Read replicas** = réplicas assíncronas (até 5). Para offload de leitura.
- **Parameter group** = arquivo `postgresql.conf` da AWS.
- **Option group** = features extras (Oracle TDE, etc).
- **Backup window / Maintenance window** = horários de backup automático e patching.
- **Performance Insights** = APM grátis para o banco. **Habilite sempre.**

### 1.3 DynamoDB

NoSQL gerenciado, **chave-valor + documento**, latência consistente em qualquer escala.

#### Conceitos chave DynamoDB

- **Tabela** = coleção de itens.
- **Item** = registro (até 400 KB).
- **Atributos** = campos do item.
- **Partition key** (PK) = "hash key", determina a partição física. Único se não tiver sort key.
- **Sort key** (SK) = "range key", ordena dentro da partition. PK+SK = chave composta.
- **GSI (Global Secondary Index)** = tabela secundária com PK/SK diferentes. Eventually consistent. Quase obrigatório.
- **LSI (Local Secondary Index)** = mesma PK, SK diferente. Definida na criação. Use raramente.
- **DynamoDB Streams** = log de mudanças (24h). Trigger Lambda em insert/update/delete.

#### Capacity modes

- **On-demand** — pay-per-request, escala automática infinita. Use para tráfego imprevisível.
- **Provisioned** — você declara RCU/WCU. ~5x mais barato em workload estável. Combine com Auto Scaling.

### 1.4 Single-table design (DynamoDB)

Padrão avançado mas **comum em produção**: uma única tabela DynamoDB armazena múltiplas entidades (User, Video, Comment, etc) usando overloading de PK/SK e GSIs.

```
PK              SK                Type      ...attrs
USER#123        PROFILE           User      name=Michel, email=...
USER#123        VIDEO#abc         WatchLog  watchedAt=...
VIDEO#abc       METADATA          Video     title=..., ...
VIDEO#abc       COMMENT#001       Comment   text=..., userId=123
```

Vantagens: menos tabelas, queries multi-entidade em uma chamada (Query por PK).
Desvantagem: aprende-se um modelo mental novo. **Leia o livro de Alex DeBrie.**

### 1.5 Aurora Serverless v2

- Auto-scaling de **0.5 ACU a 128 ACU** (Aurora Capacity Unit, ~2 GB RAM cada) em segundos.
- Você paga apenas pelas ACU em uso.
- Bom para **dev/staging** (escala para 0.5 ACU = ~US$ 30/mês de baseline) e workloads bursty.
- **Aurora Serverless v2 não pausa em zero** (ao contrário da v1). Sempre algum custo.

### 1.6 Backups e DR

- **Automated backups** RDS — retenção 0–35 dias, point-in-time recovery.
- **Manual snapshots** — sob demanda, ficam até deletados manualmente.
- **DynamoDB on-demand backup** + **PITR (35 dias)** — habilite ambos.
- **Cross-region replica** RDS / **DynamoDB Global Table** — DR continental, custa.

### 1.7 Migrações de schema

- **Ferramentas comuns:** `flyway`, `liquibase`, `prisma migrate`, `typeorm`, `node-pg-migrate`.
- **Em DynamoDB:** mudanças de schema são "code only" (não há DDL). Você adiciona novos atributos, faz backfill via script.
- **Zero-downtime migrations:** sempre **expand-and-contract** (adiciona coluna, dual-write, backfill, lê do novo, deprecate, drop).

---

## 2. Por que isso importa no streaming

- **Catálogo cresce muito** (milhões de vídeos) — DynamoDB escala sem você pensar.
- **Watch history** tem volume gigante (cada play é evento) — DynamoDB com TTL.
- **Faturamento** precisa de transações fortes — Postgres.
- **Backups** precisam ser **testados** — restore drill 1x por trimestre.
- **Latência do banco** afeta TTFB do player — cache em Redis (módulo 06) é decisivo.

---

## 3. Laboratório prático

### 🧪 Lab 5.1 — RDS Postgres em VPC privada

```bash
# Pré-requisito: VPC do módulo 02 com 2 subnets privadas em AZs diferentes.

# 1. DB Subnet Group
aws rds create-db-subnet-group \
  --db-subnet-group-name streaming-db-subnets \
  --db-subnet-group-description "Streaming DB subnets" \
  --subnet-ids subnet-priva subnet-privb

# 2. Security Group
SG_DB=$(aws ec2 create-security-group --group-name sg-db --description "RDS access" --vpc-id $VPC_ID --query GroupId --output text)
# Permite só do SG da app
aws ec2 authorize-security-group-ingress --group-id $SG_DB \
  --protocol tcp --port 5432 --source-group $SG_APP

# 3. Senha no Secrets Manager (não inline!)
aws secretsmanager create-secret --name streaming/rds/master \
  --generate-secret-string '{"SecretStringTemplate":"{\"username\":\"streamadmin\"}","GenerateStringKey":"password","PasswordLength":24,"ExcludeCharacters":"\"@/\\"}'

# 4. Cria instância (free tier)
aws rds create-db-instance \
  --db-instance-identifier streaming-postgres-lab \
  --db-instance-class db.t4g.micro \
  --engine postgres --engine-version 16.3 \
  --master-username streamadmin \
  --manage-master-user-password \
  --allocated-storage 20 --storage-type gp3 \
  --db-subnet-group-name streaming-db-subnets \
  --vpc-security-group-ids $SG_DB \
  --no-publicly-accessible \
  --backup-retention-period 7 \
  --enable-performance-insights \
  --tags Key=Project,Value=streaming-learning
```

> A flag `--manage-master-user-password` faz o RDS **criar e rotacionar** o secret. Padrão moderno.

```bash
# 5. Conecta de uma EC2 na mesma VPC
psql -h streaming-postgres-lab.xxxxxxx.us-east-1.rds.amazonaws.com -U streamadmin -d postgres
```

### 🧪 Lab 5.2 — Schema mínimo para streaming

```sql
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT UNIQUE NOT NULL,
  name TEXT NOT NULL,
  plan TEXT NOT NULL DEFAULT 'free',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE subscriptions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  plan TEXT NOT NULL,
  status TEXT NOT NULL,           -- active, canceled, past_due
  current_period_end TIMESTAMPTZ NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_subscriptions_user_id ON subscriptions(user_id);

CREATE TABLE upload_jobs (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users(id),
  source_key TEXT NOT NULL,
  status TEXT NOT NULL,           -- pending, encoding, ready, failed
  output_prefix TEXT,
  error_message TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_upload_jobs_status ON upload_jobs(status) WHERE status IN ('pending','encoding');
```

### 🧪 Lab 5.3 — DynamoDB tabela de catálogo (single-table)

```bash
aws dynamodb create-table \
  --table-name streaming-catalog \
  --attribute-definitions \
      AttributeName=PK,AttributeType=S \
      AttributeName=SK,AttributeType=S \
      AttributeName=GSI1PK,AttributeType=S \
      AttributeName=GSI1SK,AttributeType=S \
  --key-schema \
      AttributeName=PK,KeyType=HASH \
      AttributeName=SK,KeyType=RANGE \
  --global-secondary-indexes \
      "[{\"IndexName\":\"GSI1\",\"KeySchema\":[{\"AttributeName\":\"GSI1PK\",\"KeyType\":\"HASH\"},{\"AttributeName\":\"GSI1SK\",\"KeyType\":\"RANGE\"}],\"Projection\":{\"ProjectionType\":\"ALL\"}}]" \
  --billing-mode PAY_PER_REQUEST \
  --tags Key=Project,Value=streaming-learning
```

Modelo de dados:

```
# Vídeo
PK: VIDEO#<videoId>     SK: METADATA
  title, description, durationSec, status (draft|published), publishedAt
  GSI1PK: STATUS#published   GSI1SK: <publishedAt>   # listar por status ordenado

# Vídeo → asset variant (qualidade)
PK: VIDEO#<videoId>     SK: VARIANT#1080p
  bandwidth, codec, manifestKey

# Watch history do usuário
PK: USER#<userId>       SK: WATCH#<timestampDesc>#<videoId>
  positionSec, completed, lastWatchedAt
  GSI1PK: VIDEO#<videoId>   GSI1SK: USER#<userId>   # quem viu cada vídeo
```

Inserts:

```bash
aws dynamodb put-item --table-name streaming-catalog --item '{
  "PK": {"S": "VIDEO#abc123"},
  "SK": {"S": "METADATA"},
  "title": {"S": "Hello World"},
  "durationSec": {"N": "300"},
  "status": {"S": "published"},
  "publishedAt": {"S": "2026-04-26T10:00:00Z"},
  "GSI1PK": {"S": "STATUS#published"},
  "GSI1SK": {"S": "2026-04-26T10:00:00Z"}
}'
```

Query "todos os vídeos publicados ordenados por data":

```bash
aws dynamodb query --table-name streaming-catalog \
  --index-name GSI1 \
  --key-condition-expression "GSI1PK = :s" \
  --expression-attribute-values '{":s":{"S":"STATUS#published"}}' \
  --scan-index-forward false
```

### 🧪 Lab 5.4 — TTL no DynamoDB para watch history

```bash
# Adiciona atributo `expiresAt` em segundos epoch e habilita TTL
aws dynamodb update-time-to-live \
  --table-name streaming-catalog \
  --time-to-live-specification "Enabled=true, AttributeName=expiresAt"
```

Itens com `expiresAt` no passado são deletados em até 48h **sem custo**. Ótimo para watch history retida por 90 dias.

### 🧪 Lab 5.5 — DynamoDB Streams + Lambda

```bash
# Habilita stream
aws dynamodb update-table --table-name streaming-catalog \
  --stream-specification StreamEnabled=true,StreamViewType=NEW_AND_OLD_IMAGES
```

Pegue o ARN do stream e plugue uma Lambda (módulo 08) para reagir a inserts/updates (ex: indexar em OpenSearch, enviar push, atualizar contador agregado).

### 🧪 Lab 5.6 — Restore drill (DR test)

```bash
# Snapshot manual
aws rds create-db-snapshot --db-instance-identifier streaming-postgres-lab --db-snapshot-identifier drill-$(date +%Y%m%d)

# Restore para nova instância (não sobrescreve a original)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier streaming-postgres-restored \
  --db-snapshot-identifier drill-20260426 \
  --db-instance-class db.t4g.micro
```

Conecte na restaurada e confira os dados. **Apague depois.**

---

## 4. Padrões importantes

### Connection pooling

RDS Postgres: cada conexão custa RAM. App em Lambda × 1000 invocações = 1000 conexões → cai. Soluções:

- **RDS Proxy** (US$ 0.015/h por proxy) — pool gerenciado.
- **PgBouncer** rodando em ECS — DIY mais barato.
- **HikariCP / pg-pool** no app + manter Lambda concurrency limitada.

### Read/Write split

- App escreve no primário, lê de read replicas para queries pesadas (lista, search).
- Cuidado com **replica lag** (~ms a segundos).
- Postgres: configure connection string secundária no app, ou use middleware (`pg-read-replica`).

### Hot partition em DynamoDB

Se uma PK recebe 100% do tráfego, você esquentou uma partição (limite ~1k WCU / 3k RCU por partição). Sintomas: throttling em PROVISIONED, latência maior em ON-DEMAND.

Soluções: **write sharding** (`USER#123#shard0..N`), randomização de prefix.

### Backups automáticos não são de graça

Storage de snapshot = US$ 0.095/GB/mês (Postgres). Em produção com banco de 500 GB e 30 dias retenção, é centenas de USD. **Tunar retenção** conforme requisito real.

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| RDS sem Multi-AZ em prod | 1 AZ down = app fora | Multi-AZ em prod, single-AZ em dev |
| Senha em parameter texto puro | Vazamento | Secrets Manager + rotação |
| Sem read replicas para BI | OLTP lenta em horário comercial | Read replica dedicada |
| DynamoDB Provisioned subdimensionado | Throttling | On-demand para começar; provisionado depois com Auto Scaling |
| Scan em DynamoDB grande | Caro e lento | Sempre Query, nunca Scan em runtime |
| Atributos enormes em DynamoDB | Custo de RCU/WCU calculado por KB | Mover blobs para S3, guardar só URL |
| Falta de PITR / backup | Perda de dados | Backups automáticos com retenção ≥ 7d |
| Cross-AZ traffic em DB | US$ 0.01/GB cada lado | App e DB na mesma AZ quando possível |
| `t4g.micro` com 100 conexões | OOM | RDS Proxy ou instância maior |

**Custos típicos (lab):**
- RDS `db.t4g.micro` Postgres single-AZ + 20GB gp3 + 7d backup: **~US$ 14/mês** (ou US$ 0 nos primeiros 12 meses por free tier).
- DynamoDB on-demand 1M reqs/mês + 1 GB storage: **~US$ 1.5/mês**.
- Multi-AZ duplica RDS = **~US$ 28/mês**.

---

## 6. Checklist de domínio

- [ ] Sei quando escolher SQL vs NoSQL para um caso de uso.
- [ ] Subi RDS Postgres em VPC privada com SG referenciando outro SG.
- [ ] Senha do banco está no Secrets Manager com rotação.
- [ ] Habilitei Performance Insights e backups automáticos.
- [ ] Criei tabela DynamoDB single-table com PK/SK e GSI.
- [ ] Sei a diferença entre Query e Scan e custo de cada.
- [ ] Configurei TTL para dados temporários no DynamoDB.
- [ ] Habilitei DynamoDB Streams.
- [ ] Fiz restore de snapshot pelo menos uma vez (DR drill).
- [ ] Sei o que é hot partition e como mitigar.

---

## 7. Recursos

**Oficiais:**
- [RDS User Guide](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/)
- [DynamoDB Developer Guide](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/)
- [Aurora User Guide](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/)

**Livros e materiais:**
- _The DynamoDB Book_ — Alex DeBrie. **Leitura obrigatória** para single-table.
- "DynamoDB best practices" da AWS.
- "RDS Postgres tuning" — postgres.fm podcast tem episódios bons.

**Ferramentas:**
- `pgAdmin` / `DBeaver` — clientes SQL.
- `NoSQL Workbench for DynamoDB` — modelagem visual.
- `dynobase` (pago) — dashboard de DynamoDB.

---

➡️ Próximo: **Módulo 06 — Cache (Redis / ElastiCache)**.
