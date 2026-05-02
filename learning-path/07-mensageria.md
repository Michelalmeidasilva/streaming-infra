# Módulo 07 — Mensageria (SQS, SNS, EventBridge, Amazon MQ / RabbitMQ)

> **Meta do módulo:** entender as 4 ferramentas de mensageria mais usadas na AWS, escolher a certa para cada caso, e operar uma fila SQS ponta a ponta com retry e DLQ.

**Pré-requisitos:** módulos 02, 03.

---

## 1. Conceitos

### 1.1 Para que mensageria

Acoplamento síncrono (HTTP request/response) tem problemas:

- Se o consumidor está fora, produtor falha.
- Picos de tráfego derrubam consumidor.
- Lógica fica entrelaçada.

Mensageria desacopla:

- **Produtor** publica mensagem; segue a vida.
- **Broker** guarda até consumidor processar.
- **Consumidor** lê no seu ritmo, faz retry, tem DLQ.

### 1.2 As 4 opções na AWS

| Serviço | Modelo | Quando |
|---------|--------|--------|
| **SQS** | Fila ponto-a-ponto (1 produtor → 1 consumidor) | Worker queue, retry, DLQ |
| **SNS** | Pub/sub fanout (1 → N) | Notificações, broadcast |
| **EventBridge** | Event bus com schema + roteamento | Integração entre microsserviços/SaaS |
| **Amazon MQ** | RabbitMQ ou ActiveMQ gerenciado | Apps legados que falam AMQP/MQTT/STOMP |

### 1.3 SQS — Simple Queue Service

**Filas:**
- **Standard** — at-least-once, ordem best-effort, throughput ilimitado. **Padrão.**
- **FIFO** — exactly-once, ordem garantida por `MessageGroupId`. 300 reqs/s/group sem batch, 3000 com batch.

**Conceitos:**
- **Visibility timeout** — quando consumidor lê, a mensagem fica "invisível" por N segundos. Se não deletar até lá, volta para a fila.
- **Long polling** (`WaitTimeSeconds=20`) — reduz custo e latência (vs short polling).
- **DLQ** (Dead Letter Queue) — após N tentativas, mensagem vai pra outra fila para inspeção.
- **Redrive** — reprocessar de DLQ → fila principal.

**Custo:** US$ 0.40 por 1M reqs (Standard); US$ 0.50 (FIFO). 1M grátis/mês.

> 💡 Para streaming, SQS é onde **jobs de encoding** vão ser enfileirados e workers EC2 GPU vão consumir.

### 1.4 SNS — Simple Notification Service

Pub/sub: 1 publish → N subscribers.

**Subscribers:**
- SQS (fanout para várias filas).
- Lambda.
- HTTP/HTTPS endpoint.
- E-mail (SMTP).
- SMS (cuidado, caro).
- **Mobile push** (APNS, FCM).

**Filtragem:** subscription pode ter **filter policy** para receber só subset.

**Padrão clássico:** SNS → múltiplas SQSs (cada microsserviço tem sua própria fila com retry/DLQ separada).

### 1.5 EventBridge

Event bus com **schema discovery** e **roteamento por padrão**.

**Conceitos:**
- **Event bus** — onde eventos chegam (default + custom buses + partner buses para SaaS).
- **Rule** — pattern de match + targets.
- **Target** — Lambda, SQS, SNS, ECS task, API destination, etc (até 5 por rule).
- **Schema registry** — tipa eventos automaticamente.
- **Pipes** — connector de fonte (SQS, Kinesis, DynamoDB Stream) → enrichment → target. Substitui Lambda glue.
- **Scheduler** — substituto moderno do CloudWatch Events scheduled rules (cron na AWS).

**Quando usar EventBridge vs SNS:**
- **SNS:** broadcast simples para alguns subscribers fixos.
- **EventBridge:** mais de um produtor, padrões complexos, integração SaaS, schema importante.

**Custo:** US$ 1 por milhão de events (default bus grátis para AWS service events).

### 1.6 Amazon MQ (RabbitMQ gerenciado)

Para quem **já fala AMQP / MQTT / STOMP** ou tem app legado dependente de RabbitMQ/ActiveMQ.

**Modos:**
- **Single instance** — 1 broker, baixa disponibilidade.
- **Cluster (RabbitMQ)** — 3 brokers em AZs diferentes.
- **Active/Standby (ActiveMQ)** — failover.

**Custo:** ~US$ 0.30/h por broker `mq.t3.micro` (~US$ 220/mês para cluster de 3).

> ⚠️ Se está começando do zero, **prefira SQS+SNS+EventBridge** (nativos, mais baratos, sem patching). MQ só se for migração legada.

### 1.7 Quando escolher cada um (decision tree)

```
- Você tem app que já fala AMQP/MQTT? → MQ.
- Você precisa que UM consumidor processe cada mensagem? → SQS.
- Você precisa BROADCAST para vários consumidores fixos? → SNS (ou SNS→SQS por consumer).
- Você quer roteamento por padrão de evento, integração entre vários services e SaaS? → EventBridge.
- Você precisa de eventos ordenados ou exactly-once? → SQS FIFO ou Kinesis.
- Você quer processar stream de dados (analytics, ML)? → Kinesis Data Streams.
```

### 1.8 Padrões de mensageria

#### Outbox pattern

Para garantir consistência entre **DB write + mensagem**: app grava em uma tabela `outbox` na mesma transação. Worker lê outbox e publica.

#### Saga (orquestração vs coreografia)

Workflow distribuído com compensação. Em AWS, **Step Functions** orquestra; **EventBridge** coreografa.

#### Idempotency

Consumer deve aguentar a **mesma mensagem 2x** (SQS Standard é at-least-once). Use chave de idempotência (`messageId`, ou `eventId`) e tabela DynamoDB com TTL.

#### Backoff e retry

Worker que falha não deve receber a mesma mensagem em loop apertado:
- Visibility timeout aumentado a cada retry.
- DLQ após `maxReceiveCount` tentativas.
- Delay queue (mensagem aparece após N segundos).

---

## 2. Por que isso importa no streaming

Pipeline típico:

```
Upload S3 → EventBridge (S3 event) → Rule
                                       ├── SQS (encoding queue) → Worker EC2 GPU (FFmpeg)
                                       └── SNS (analytics topic) → Lambda (registra job)
                                       └── DynamoDB Stream → outras reações

Worker conclui → publica em SNS "encoding-finished"
                          ├── SQS (notifications) → Lambda (envia push/email)
                          ├── SQS (catalog-update) → Lambda (atualiza DynamoDB)
                          └── SQS (cdn-warm) → Lambda (warm CloudFront cache)
```

Por que vale tanto:

- Pico de uploads não derruba o encoder (fila amortece).
- Worker pode reiniciar (visibility timeout segura mensagem).
- Falhas vão pra DLQ — você inspeciona, conserta, redrive.
- Adicionar consumidor (ex: integração com analytics) = uma nova SQS subscrita, sem alterar código existente.

---

## 3. Laboratório prático

### 🧪 Lab 7.1 — SQS Standard com DLQ

```bash
# DLQ primeiro
DLQ_URL=$(aws sqs create-queue --queue-name encoder-dlq \
  --attributes '{"MessageRetentionPeriod":"1209600"}' \
  --query QueueUrl --output text)
DLQ_ARN=$(aws sqs get-queue-attributes --queue-url $DLQ_URL \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

# Fila principal
QUEUE_URL=$(aws sqs create-queue --queue-name encoder-jobs \
  --attributes '{
    "VisibilityTimeout":"600",
    "ReceiveMessageWaitTimeSeconds":"20",
    "MessageRetentionPeriod":"345600",
    "RedrivePolicy":"{\"deadLetterTargetArn\":\"'$DLQ_ARN'\",\"maxReceiveCount\":\"3\"}"
  }' --query QueueUrl --output text)
```

Configurações importantes:
- `VisibilityTimeout=600` — 10 minutos (encoding longo).
- `ReceiveMessageWaitTimeSeconds=20` — long polling (sempre).
- `maxReceiveCount=3` — 3 tentativas e vai pra DLQ.

### 🧪 Lab 7.2 — Publish/consume

```bash
# Publish
aws sqs send-message --queue-url $QUEUE_URL \
  --message-body '{"jobId":"j1","s3Key":"uploads/abc.mp4"}' \
  --message-attributes 'priority={DataType=String,StringValue=high}'

# Consume (long poll)
aws sqs receive-message --queue-url $QUEUE_URL \
  --max-number-of-messages 10 \
  --wait-time-seconds 20

# Delete (após processar)
aws sqs delete-message --queue-url $QUEUE_URL \
  --receipt-handle <recebido-no-receive>
```

### 🧪 Lab 7.3 — SNS topic com fanout para SQS

```bash
# Topic
TOPIC=$(aws sns create-topic --name encoding-events --query TopicArn --output text)

# 2 filas consumidoras
NOTIF_URL=$(aws sqs create-queue --queue-name notifications --query QueueUrl --output text)
NOTIF_ARN=$(aws sqs get-queue-attributes --queue-url $NOTIF_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

CATALOG_URL=$(aws sqs create-queue --queue-name catalog-update --query QueueUrl --output text)
CATALOG_ARN=$(aws sqs get-queue-attributes --queue-url $CATALOG_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

# Permite SNS publicar nas filas
for q in $NOTIF_URL $CATALOG_URL; do
  aws sqs set-queue-attributes --queue-url $q --attributes "$(cat <<EOF
{"Policy": "{\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"sns.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"*\",\"Condition\":{\"ArnEquals\":{\"aws:SourceArn\":\"$TOPIC\"}}}]}"}
EOF
)"
done

# Subscriptions com filter policy
aws sns subscribe --topic-arn $TOPIC --protocol sqs --notification-endpoint $NOTIF_ARN \
  --attributes '{"FilterPolicy":"{\"event\":[\"finished\",\"failed\"]}", "RawMessageDelivery":"true"}'

aws sns subscribe --topic-arn $TOPIC --protocol sqs --notification-endpoint $CATALOG_ARN \
  --attributes '{"FilterPolicy":"{\"event\":[\"finished\"]}", "RawMessageDelivery":"true"}'

# Publica
aws sns publish --topic-arn $TOPIC --message '{"event":"finished","videoId":"abc"}'
```

> **`RawMessageDelivery=true`** evita o wrapper SNS e entrega o JSON puro na SQS.

### 🧪 Lab 7.4 — EventBridge: regra para upload S3

```bash
# 1. Bus default já existe. Habilita S3 events to EventBridge no bucket
aws s3api put-bucket-notification-configuration --bucket $BUCKET \
  --notification-configuration '{"EventBridgeConfiguration":{}}'

# 2. Rule: novos uploads no prefix uploads/
aws events put-rule --name s3-uploads-rule --event-pattern '{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": { "name": ["'$BUCKET'"] },
    "object": { "key": [ {"prefix": "uploads/"} ] }
  }
}'

# 3. Target: a SQS encoder-jobs
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
aws events put-targets --rule s3-uploads-rule --targets '[{"Id":"1","Arn":"'$QUEUE_ARN'"}]'

# 4. Permite EventBridge publicar na SQS
aws sqs set-queue-attributes --queue-url $QUEUE_URL --attributes "$(cat <<EOF
{"Policy":"{\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"events.amazonaws.com\"},\"Action\":\"sqs:SendMessage\",\"Resource\":\"$QUEUE_ARN\"}]}"}
EOF
)"

# 5. Teste: faça upload em uploads/
aws s3 cp test.mp4 s3://$BUCKET/uploads/test.mp4
# Veja a mensagem chegando em encoder-jobs
```

### 🧪 Lab 7.5 — EventBridge Scheduler (cron na AWS)

```bash
aws scheduler create-schedule --name daily-cleanup \
  --schedule-expression "cron(0 3 * * ? *)" \
  --schedule-expression-timezone "America/Sao_Paulo" \
  --target '{"Arn":"arn:aws:lambda:us-east-1:123:function:cleanup", "RoleArn":"arn:aws:iam::123:role/scheduler-role"}' \
  --flexible-time-window '{"Mode":"OFF"}'
```

### 🧪 Lab 7.6 — Idempotency table

```bash
aws dynamodb create-table --table-name processed-messages \
  --attribute-definitions AttributeName=messageId,AttributeType=S \
  --key-schema AttributeName=messageId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

aws dynamodb update-time-to-live --table-name processed-messages \
  --time-to-live-specification "Enabled=true,AttributeName=expiresAt"
```

No worker, antes de processar:

```ts
// pseudo
const exists = await dynamo.put({
  TableName: 'processed-messages',
  Item: { messageId, expiresAt: Math.floor(Date.now()/1000) + 86400 },
  ConditionExpression: 'attribute_not_exists(messageId)',
}).catch(e => e.code === 'ConditionalCheckFailedException' ? 'duplicate' : Promise.reject(e));
if (exists === 'duplicate') { return; /* já processado */ }
// processa...
```

---

## 4. Padrões e decisões

### Visibility timeout = ?

Regra: **2× tempo p99 esperado** + buffer. Encoding de 5 min → VT 15 min.

Se o worker pode ser longo, use **`change-message-visibility`** durante o processamento para estender.

### Batch send/receive

`SendMessageBatch` (até 10) e `ReceiveMessage` (até 10) reduzem custo e latência.

### Throttling de Lambda consumindo SQS

Lambda escala até 1000 invocations concorrentes por fila por padrão. Em poucas mensagens grandes, ok. Em milhares pequenas, configure `ReservedConcurrency` para não estourar limite global.

### Mensagens grandes (> 256 KB)

SQS limita a 256 KB. Para payloads maiores: **Extended Client Library** (sobe payload no S3 e refere por handle) — mas raramente é a abordagem certa. Geralmente é melhor: salvar S3 → mandar referência (`s3Key`) na fila.

### EventBridge Pipes

Para conectar SQS → Lambda → SQS sem escrever Lambda glue:

```bash
aws pipes create-pipe --name s3-to-encoder --role-arn ... \
  --source-arn $QUEUE_ARN --target-arn $TARGET_QUEUE \
  --enrichment arn:aws:lambda:...:function:transform
```

---

## 5. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Visibility timeout curto | Mensagem reaparece processada 2x | VT = 2× p99 + buffer |
| Sem DLQ | Mensagem ruim faz consumer travar para sempre | Sempre DLQ + alarm com `ApproximateNumberOfMessagesVisible` em DLQ > 0 |
| Short polling | Custo e latência | `ReceiveMessageWaitTimeSeconds=20` |
| Sem idempotency | Side effect duplicado | Tabela com TTL |
| FIFO sem `MessageGroupId` certo | Throughput de uma fila baixinha | Group por `userId` ou `videoId` |
| SNS sem filter policy | Lambda inundada | Sempre filter policy |
| EventBridge default bus em prod | Mistura com eventos AWS | Custom event bus por domínio |
| MQ usado por moda | Custo alto sem necessidade | SQS+SNS resolve 95% |

**Custos típicos:**
- SQS: 10M msgs/mês = US$ 4.
- SNS: 10M publications + 1M SMS BR = US$ 0.50 + US$ 200 (SMS é caro!).
- EventBridge: 10M events = US$ 10.
- Amazon MQ cluster RabbitMQ 3 nós `mq.t3.micro`: ~US$ 220/mês.

---

## 6. Checklist de domínio

- [ ] Sei explicar a diferença entre SQS, SNS, EventBridge e MQ.
- [ ] Criei fila SQS Standard com DLQ e maxReceiveCount.
- [ ] Configurei visibility timeout adequado para job longo.
- [ ] Subi tópico SNS com fanout para 2+ SQSs com filter policy.
- [ ] Habilitei EventBridge no S3 e roteei evento "Object Created" para SQS.
- [ ] Implementei idempotency com DynamoDB conditional put.
- [ ] Sei o que é redrive de DLQ e como executar.
- [ ] Sei quando NÃO usar MQ (quase sempre).
- [ ] Configurei alarme em DLQ > 0.

---

## 7. Recursos

**Oficiais:**
- [SQS Developer Guide](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/)
- [SNS Developer Guide](https://docs.aws.amazon.com/sns/latest/dg/)
- [EventBridge User Guide](https://docs.aws.amazon.com/eventbridge/latest/userguide/)
- [Amazon MQ User Guide](https://docs.aws.amazon.com/amazon-mq/latest/developer-guide/)

**Posts e talks:**
- "Messaging patterns for microservices" — re:Invent.
- AWS Compute Blog tag "messaging".
- "EventBridge in production" — Yan Cui (theburningmonk.com).

**Livros:**
- _Enterprise Integration Patterns_ — Hohpe & Woolf (clássico, vale anos depois).

---

➡️ Próximo: **Módulo 08 — Compute (EC2, ECS, Lambda)**.
