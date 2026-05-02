# Módulo 06 — Cache & Redis (ElastiCache)

> **Meta do módulo:** entender padrões de cache, subir Redis gerenciado (ElastiCache) e aplicar nos casos críticos da plataforma de streaming: sessão, manifesto, contadores e fila leve.

**Pré-requisitos:** módulos 02, 05.

---

## 1. Conceitos

### 1.1 Para que serve cache

Cache = camada **rápida e barata** entre aplicação e fonte de verdade (banco, API externa).

Motivações:
- **Latência** — Redis responde em < 1ms; Postgres em 5–50ms.
- **Custo** — uma query custa CPU/IO no banco; uma cache hit é trivial.
- **Resiliência** — banco caído por minutos não derruba o produto.
- **Throughput** — hot partition escala para outro lado.

### 1.2 Anatomia: cliente, servidor, padrões

Padrão dominante: **Redis** (Remote Dictionary Server). Estrutura de dados em memória, single-thread, persistência opcional (RDB/AOF).

Estruturas suportadas:

- **String** — valor simples (`SET k v`).
- **Hash** — objeto com campos (`HSET user:1 name Michel`).
- **List** — fila/pilha (`LPUSH`, `RPOP`).
- **Set** — coleção sem ordem, sem duplicatas.
- **Sorted set (ZSet)** — set ordenado por score (rankings, top-N).
- **Stream** — log append-only (Redis Streams).
- **HyperLogLog** — contagem aproximada.
- **Geo** — coordenadas + busca por raio.

### 1.3 ElastiCache

Serviço gerenciado da AWS para Redis e Memcached. Você foca em uso, AWS cuida de infra.

**Modos de deploy do Redis no ElastiCache:**

| Modo | O que é | Quando |
|------|---------|--------|
| **Standalone** (cluster mode disabled, 1 node) | 1 primary | Lab apenas |
| **Replication group** (cluster mode disabled) | 1 primary + N replicas | Maioria dos casos: HA + read-scale |
| **Cluster mode enabled** | sharding (hash slots) | Datasets > RAM de 1 nó, ou > ~70k ops/s |
| **Serverless** (lançado 2023) | escala automática, paga por GB-h e ECPU | Workload imprevisível, dev/staging |

> 💡 **Recomendação inicial:** `cache.t4g.micro` com 1 primary + 1 replica em outra AZ. ~US$ 25/mês. Multi-AZ + automatic failover habilitado.

### 1.4 Memcached vs Redis

Use **Redis**. Memcached só faz sentido se você precisa de cache puro chave-valor multi-thread em padrão muito antigo. Redis ganha em recursos, persistência, replicação, pub/sub.

### 1.5 Padrões de cache

#### Cache-aside (lazy loading)

```
1. App pergunta ao cache.
2. MISS → app busca no DB → salva no cache → retorna.
3. HIT → retorna direto.
```

Pros: simples, cache só com dados realmente lidos.
Cons: stampede em chave fria; staleness se DB muda.

#### Write-through

```
1. App escreve no DB.
2. App escreve no cache (mesma operação).
```

Pros: cache sempre fresco.
Cons: cada write = 2 ops; cache pode encher de dados nunca lidos.

#### Write-behind (write-back)

App escreve no cache; cache flusha para DB assíncrono.
Raro em Redis padrão (perde durabilidade).

#### Read-through

Cache **chama o DB sozinho** em miss. Requer integração (algumas libs como Redis Enterprise fazem; em ElastiCache padrão, você implementa via cache-aside).

### 1.6 TTL e estratégias de invalidação

- **TTL** — sempre defina (`SET k v EX 60`). Sem TTL é receita para staleness eterna.
- **Invalidation por evento** — quando o registro muda, dispara `DEL chave`.
- **Versioned key** — `user:1:v3` no lugar de `user:1`. Para invalidar, incrementa versão. Útil para invalidar "tudo de um usuário".
- **Soft TTL** — armazena com TTL longo + timestamp; se item está velho, refresh em background.

### 1.7 Casos de uso clássicos em streaming

1. **Sessão de usuário** (JWT já cobre, mas se quiser revogar) — `session:<token>`.
2. **Cache de catálogo** — vídeo metadata por `videoId`.
3. **Manifesto HLS** — pequeno, lido milhares de vezes.
4. **Contadores de views / likes** — `INCR video:abc:views`.
5. **Rate limiting** — token bucket por usuário.
6. **Fila leve** — `BLPOP` para workers (não substitui SQS para retry/DLQ).
7. **Pub/Sub** — notificações em tempo real (mas considere SNS+WebSocket no API Gateway).
8. **Idempotency keys** — armazenar IDs de requests já processados.
9. **Distributed lock** — Redlock para tasks únicas (cuidado: padrão complicado).

### 1.8 Eviction policies

Quando o Redis enche, política de despejo:

- `noeviction` — erro ao gravar mais. **NÃO use em cache.**
- `allkeys-lru` — despeja menos recentemente usadas. Padrão de cache.
- `allkeys-lfu` — menos frequentemente usadas (4.0+).
- `volatile-ttl` — só itens com TTL, expirando primeiro.

Configure no parameter group: `maxmemory-policy = allkeys-lru`.

### 1.9 Persistência

Redis pode persistir em disco com:

- **RDB snapshot** (a cada N minutos).
- **AOF** (append-only file, fsync por config).

**ElastiCache:** padrão é só RDB diário. Para cache puro, você não precisa. Para uso como "datastore primário simples", configure AOF.

### 1.10 Cluster vs Replication group

- **Replication group (cluster disabled):** dataset cabe em 1 nó. Replicas são read-replicas. Failover automático em ~30s.
- **Cluster enabled (sharded):** dataset dividido em 16384 hash slots. Cliente precisa de **cluster client**. Não tem multi-key transactions cross-slot.

> Para começar e quase sempre: **cluster disabled** com 1 primary + 1 replica. Migre para cluster enabled só quando precisar.

---

## 2. Por que isso importa no streaming

- **Catálogo** lido por TODO viewer. Hit em Redis = ms; miss em Postgres com JOIN = dezenas de ms × milhões de viewers = caos.
- **Watch position** atualiza a cada N segundos. Escrever sempre no DynamoDB é caro; escrever no Redis e persistir periodicamente é barato.
- **Manifesto HLS** muda raramente, é lido em loop. Cache em Redis (ou no próprio CloudFront) reduz origin requests para zero.
- **Rate limit de presigned URLs** — você não quer alguém pegando 10k URLs/min. Token bucket em Redis.

---

## 3. Laboratório prático

### 🧪 Lab 6.1 — Subir um replication group ElastiCache

```bash
# 1. Subnet group
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name streaming-cache-subnets \
  --cache-subnet-group-description "Streaming cache subnets" \
  --subnet-ids subnet-priva subnet-privb

# 2. Security group
SG_REDIS=$(aws ec2 create-security-group --group-name sg-redis --description "Redis access" --vpc-id $VPC_ID --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id $SG_REDIS --protocol tcp --port 6379 --source-group $SG_APP

# 3. Replication group
aws elasticache create-replication-group \
  --replication-group-id streaming-redis-lab \
  --replication-group-description "Streaming Redis lab" \
  --engine redis \
  --engine-version 7.1 \
  --cache-node-type cache.t4g.micro \
  --num-cache-clusters 2 \
  --automatic-failover-enabled \
  --multi-az-enabled \
  --cache-subnet-group-name streaming-cache-subnets \
  --security-group-ids $SG_REDIS \
  --transit-encryption-enabled \
  --at-rest-encryption-enabled \
  --tags Key=Project,Value=streaming-learning
```

> Habilite **encryption in transit + at rest** desde lab — mesmas configs serão portadas para prod.

```bash
# Endpoint primary
aws elasticache describe-replication-groups \
  --replication-group-id streaming-redis-lab \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint'
```

### 🧪 Lab 6.2 — Conectar de uma EC2 / ECS

```bash
# Em EC2 com SG_APP, instale redis-cli
sudo dnf install -y redis6  # Amazon Linux 2023
redis-cli -h <primary-endpoint> --tls -p 6379

127.0.0.1:6379> SET videos:abc:title "Hello World" EX 300
OK
127.0.0.1:6379> GET videos:abc:title
"Hello World"
127.0.0.1:6379> INCR videos:abc:views
(integer) 1
```

### 🧪 Lab 6.3 — Cache-aside em Node.js (NestJS service)

```ts
// videos.service.ts
import { Injectable } from '@nestjs/common';
import IORedis from 'ioredis';

const TTL = 300; // 5 min

@Injectable()
export class VideosService {
  private redis = new IORedis({
    host: process.env.REDIS_HOST,
    port: 6379,
    tls: {},
  });

  async findById(id: string): Promise<Video | null> {
    const key = `video:${id}:v1`;
    const cached = await this.redis.get(key);
    if (cached) return JSON.parse(cached);

    const row = await this.db.query('SELECT * FROM videos WHERE id = $1', [id]);
    if (!row) return null;

    await this.redis.set(key, JSON.stringify(row), 'EX', TTL);
    return row;
  }

  async update(id: string, patch: Partial<Video>): Promise<void> {
    await this.db.query('UPDATE videos SET ... WHERE id = $1', [id]);
    await this.redis.del(`video:${id}:v1`); // invalida
  }
}
```

### 🧪 Lab 6.4 — Rate limiting com token bucket

```lua
-- rate_limit.lua (executa atomicamente via EVAL)
local key = KEYS[1]
local capacity = tonumber(ARGV[1])
local refill_rate = tonumber(ARGV[2]) -- tokens/segundo
local now = tonumber(ARGV[3])

local data = redis.call('HMGET', key, 'tokens', 'last')
local tokens = tonumber(data[1]) or capacity
local last = tonumber(data[2]) or now

local delta = math.max(0, now - last) * refill_rate
tokens = math.min(capacity, tokens + delta)

local allowed = 0
if tokens >= 1 then
  tokens = tokens - 1
  allowed = 1
end

redis.call('HMSET', key, 'tokens', tokens, 'last', now)
redis.call('EXPIRE', key, 60)
return allowed
```

```ts
const allowed = await redis.eval(
  rateLimitLua,
  1,
  `rl:user:${userId}`,
  10,            // capacity (10 reqs)
  1,             // 1 token/segundo
  Math.floor(Date.now()/1000)
);
if (!allowed) throw new HttpException('Too many requests', 429);
```

### 🧪 Lab 6.5 — Pub/Sub para notificações de player

```bash
# Terminal 1
redis-cli -h ... --tls SUBSCRIBE video:abc:status

# Terminal 2
redis-cli -h ... --tls PUBLISH video:abc:status '{"status":"ready"}'
```

> Use para invalidação de cache cross-instância: quando um node atualiza, publica `invalidate video:abc`. Outros nodes assinam e dão `DEL`.

### 🧪 Lab 6.6 — Testando failover

```bash
# Force failover manual
aws elasticache test-failover \
  --replication-group-id streaming-redis-lab \
  --node-group-id 0001
```

Observe que o endpoint primary continua o mesmo (DNS aponta para o novo primary). App não precisa de mudança se usa endpoint primary.

---

## 4. Padrões e armadilhas avançadas

### Cache stampede (thundering herd)

10k requests para item recém-expirado batem todos no DB. Soluções:
- **Lock + single flight** — primeiro request adquire lock, outros esperam.
- **Probabilistic early refresh** — antes do TTL expirar, ~10% dos requests refresham.
- **Stale-while-revalidate** — TTL hard maior; refresh background quando "soft TTL" passa.

### Big keys

Chaves > 1 MB causam latência. Quebre em partes (`video:abc:meta`, `video:abc:variants`, `video:abc:comments:page1`).

### Hot keys

Toda a internet pedindo `video:trending` causa hot key. Soluções:
- Local cache no app (TTL curto) na frente do Redis.
- Read replicas com leitura distribuída.

### Não armazene tudo

Cache **leituras quentes**, não tudo. Itens lidos 1x = poluição de cache.

### Connection pooling

Cada conexão é socket TCP. Em Lambda, reuse cliente entre invocations (variável global). Em NestJS, providers são singletons — ok.

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Sem TTL em chaves | Memória enchendo, eviction agressiva | Sempre `EX` no `SET` |
| Maxmemory-policy padrão `noeviction` | App quebra com OOM | Mude para `allkeys-lru` |
| Comando `KEYS *` em prod | Bloqueia o nó (single-thread) | Use `SCAN` |
| Pipeline ausente para muitos cmds | RTT mata performance | `MULTI` ou pipeline do client |
| Cluster client em modo sharded esquecido | "MOVED" errors | Use cluster client, hash tag `{}` |
| Sem encryption in transit | Audit fail | Sempre TLS |
| `cache.t2.micro` (geração antiga) | Mais caro, menos performance | Use `t4g.micro` (Graviton ARM) |
| Persistência AOF cara em IOPS | EBS spend alto | Cache puro: desabilite AOF |

**Custos típicos (lab):**
- `cache.t4g.micro` × 2 nodes (primary + replica) Multi-AZ: **~US$ 25/mês**.
- `cache.r7g.large` (13.0 GB, prod): ~US$ 175/nó/mês.
- ElastiCache Serverless: minimum ~US$ 90/mês por cluster (mais caro para cargas pequenas constantes).

---

## 6. Checklist de domínio

- [ ] Sei explicar quando usar cache-aside vs write-through.
- [ ] Subi replication group com 1 primary + 1 replica e Multi-AZ.
- [ ] Conectei via TLS de um EC2 dentro da VPC.
- [ ] Implementei cache-aside no app com TTL.
- [ ] Sei qual eviction policy usar para cache puro.
- [ ] Implementei rate limit (token bucket) em Lua.
- [ ] Sei o que é cache stampede e uma forma de mitigar.
- [ ] Forcei failover manual e o app sobreviveu.
- [ ] Sei o custo aproximado de um cluster `t4g.micro` × 2 nós.

---

## 7. Recursos

**Oficiais:**
- [ElastiCache for Redis User Guide](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/)
- [Redis docs](https://redis.io/docs/)

**Materiais:**
- "Caching strategies" — AWS Whitepaper de caching.
- _Redis Best Practices_ (livro grátis Redis Labs).
- Salvatore Sanfilippo (criador) — blog antirez.com.

**Ferramentas:**
- `redis-cli` — sempre.
- `RedisInsight` — GUI oficial.
- `ioredis` (Node), `redis-py`, `go-redis` — clientes maduros.

---

➡️ Próximo: **Módulo 07 — Mensageria (SQS, SNS, EventBridge, Amazon MQ)**.
