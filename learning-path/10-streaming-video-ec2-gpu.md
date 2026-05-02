# Módulo 10 — Pipeline de transcodificação em EC2 GPU

> **Meta do módulo:** construir um pipeline de VOD que recebe vídeo bruto em S3, transcoda em múltiplos bitrates (HLS/DASH) usando FFmpeg em instâncias EC2 GPU via fila SQS, e entrega via CloudFront.

**Pré-requisitos:** módulos 02, 03, 04, 07, 08.

---

## 1. Arquitetura do pipeline

```
[Usuário] ──presigned PUT──▶ S3 (uploads/)
                                │
                         EventBridge (Object Created)
                                │
                         SQS (encoder-jobs)
                                │
                     ┌──────────▼──────────┐
                     │  EC2 GPU (g4dn)     │
                     │  Spot + ASG         │
                     │  FFmpeg + NVENC     │
                     │  Worker Node.js     │
                     └──────────┬──────────┘
                                │ HLS + DASH segments
                          S3 (encoded/)
                                │
                         CloudFront (signed cookies)
                                │
                         [Player HTML5]
                                │
                     ┌──────────▼──────────┐
                     │  SNS (job events)   │
                     ├─ SQS (catalog)      │──▶ Lambda atualiza DynamoDB
                     └─ SQS (notif)        │──▶ Lambda envia push/email
```

---

## 2. Conceitos

### 2.1 Codecs e containers

| Codec | Container | Quando |
|-------|-----------|--------|
| H.264 (AVC) | MP4, HLS, DASH | Compatibilidade máxima, padrão |
| H.265 (HEVC) | HLS, MP4 | 40% menos bitrate; iOS Safari, macOS |
| VP9 | WebM, DASH | Android Chrome, mais compressão |
| AV1 | MP4, DASH | Futuro, mais eficiente; encoding lento |

> Para a maioria das plataformas: **H.264 como baseline + H.265 para dispositivos Apple modernos**.

### 2.2 Adaptive Bitrate Streaming (ABR)

Vídeo encodado em múltiplas qualidades. Player escolhe qual baixar baseado na largura de banda:

| Qualidade | Resolução | Bitrate vídeo | Bitrate áudio |
|-----------|-----------|---------------|---------------|
| 360p | 640×360 | 400 kbps | 64 kbps |
| 540p | 960×540 | 1000 kbps | 128 kbps |
| 720p | 1280×720 | 2500 kbps | 128 kbps |
| 1080p | 1920×1080 | 5000 kbps | 192 kbps |
| 1440p | 2560×1440 | 10000 kbps | 192 kbps |
| 4K | 3840×2160 | 20000 kbps | 192 kbps |

### 2.3 HLS (HTTP Live Streaming)

Desenvolvido pela Apple, agora padrão universal.

```
index.m3u8 (master playlist)
  ├── 360p.m3u8  → seg-0001.ts, seg-0002.ts ...
  ├── 720p.m3u8  → seg-0001.ts, seg-0002.ts ...
  └── 1080p.m3u8 → seg-0001.ts, seg-0002.ts ...
```

- Segmentos `.ts` de 6–10 segundos.
- Master playlist referencia renditions com bandwidth declarado.
- Player pede próximo segmento antes do atual terminar.

### 2.4 DASH (MPEG-DASH)

Similar ao HLS, mas aberto. Mais comum em Android e Smart TV.

```
manifest.mpd
  └── AdaptationSet video H264
        ├── Representation 360p ... → chunk-0001.m4s
        ├── Representation 720p ... → chunk-0001.m4s
```

> Você pode gerar ambos HLS e DASH em paralelo no mesmo encoding job.

### 2.5 FFmpeg e NVENC

**FFmpeg** = ferramenta CLI open-source de codificação de vídeo. Suporta GPU via **NVENC** (NVIDIA) ou **AMF** (AMD).

Sem GPU (CPU):
```bash
# H.264 via libx264 (lento, qualidade alta)
ffmpeg -i input.mp4 -c:v libx264 -crf 23 -preset medium output.mp4
# ~30-60 fps em CPU t3, 1 min de 1080p leva 10-30 min em CPU
```

Com GPU NVENC (g4dn):
```bash
# H.264 via h264_nvenc (rápido, qualidade ligeiramente menor que libx264)
ffmpeg -hwaccel cuda -hwaccel_output_format cuda \
  -i input.mp4 -c:v h264_nvenc -preset p4 -rc vbr -cq 28 \
  -b:v 5M -maxrate 8M -bufsize 10M output.mp4
# ~200-300 fps em g4dn.xlarge. 1 min de 1080p em ~10-20 segundos
```

> **Regra prática:** GPU (NVENC) é 10–30× mais rápido para encoding que CPU equivalente em custo.

### 2.6 Instâncias GPU para encoding

| Instância | GPU | vCPU | RAM | Spot (~) | NVENC streams |
|-----------|-----|------|-----|----------|---------------|
| `g4dn.xlarge` | 1× T4 | 4 | 16 GB | ~US$0.16/h | 3 simultâneos |
| `g4dn.2xlarge` | 1× T4 | 8 | 32 GB | ~US$0.23/h | 3 simultâneos |
| `g5.xlarge` | 1× A10G | 4 | 16 GB | ~US$0.32/h | 5 simultâneos |
| `g5.2xlarge` | 1× A10G | 8 | 32 GB | ~US$0.45/h | 5 simultâneos |

> A T4 tem 3 streams NVENC simultâneos. Para paralelizar, encode 3 qualidades em paralelo em 1 job.

### 2.7 Spot interrupt handler

EC2 Spot envia SIGTERM 2 minutos antes de terminar. O worker deve:

1. Parar de pegar novas mensagens da SQS.
2. Mudar visibility da mensagem atual para 0 (devolve pra fila).
3. Gracefully shutdown.

```bash
# Instance metadata v2 - spot interruption notice
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/spot/interruption-notice
```

---

## 3. Laboratório prático

### 🧪 Lab 10.1 — AMI para worker GPU

```bash
# Bootstrap script para EC2 GPU (salvar como encoder-bootstrap.sh)
cat > encoder-bootstrap.sh << 'BOOTSTRAP'
#!/bin/bash
set -e

# Atualiza
dnf update -y

# NVIDIA driver (Amazon Linux 2023)
dnf install -y gcc kernel-headers kernel-devel
curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-keyring_1.1-1_all.rpm -o cuda-keyring.rpm
rpm -i cuda-keyring.rpm
dnf install -y cuda-toolkit-12-4

# FFmpeg com suporte NVENC
dnf install -y ffmpeg

# Node.js 20
dnf install -y nodejs npm

# Instala worker
mkdir -p /opt/encoder
cd /opt/encoder
# worker será copiado do S3 ou via CodeDeploy (módulo 15)
aws s3 cp s3://streaming-deploy/encoder/worker.zip .
unzip worker.zip
npm ci --only=production

# Systemd service
cat > /etc/systemd/system/encoder.service << 'UNIT'
[Unit]
Description=Video Encoder Worker
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/encoder
ExecStart=/usr/bin/node /opt/encoder/worker.js
Restart=on-failure
RestartSec=10
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable encoder
systemctl start encoder
BOOTSTRAP
```

### 🧪 Lab 10.2 — Worker Node.js

```js
// worker.js
import { SQSClient, ReceiveMessageCommand, DeleteMessageCommand, ChangeMessageVisibilityCommand } from '@aws-sdk/client-sqs';
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { SNSClient, PublishCommand } from '@aws-sdk/client-sns';
import { execSync, spawn } from 'child_process';
import { createWriteStream, mkdtempSync, rmSync } from 'fs';
import { tmpdir } from 'os';
import { join } from 'path';
import http from 'http';

const sqs = new SQSClient({ region: 'us-east-1' });
const s3 = new S3Client({ region: 'us-east-1' });
const sns = new SNSClient({ region: 'us-east-1' });

const QUEUE_URL = process.env.ENCODER_QUEUE_URL;
const INPUT_BUCKET = process.env.INPUT_BUCKET;
const OUTPUT_BUCKET = process.env.OUTPUT_BUCKET;
const SNS_TOPIC = process.env.EVENTS_TOPIC_ARN;

let shuttingDown = false;

// Spot interruption monitor
async function checkInterruption() {
  try {
    const token = await fetch('http://169.254.169.254/latest/api/token', {
      method: 'PUT',
      headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '21600' }
    }).then(r => r.text());
    const res = await fetch('http://169.254.169.254/latest/meta-data/spot/interruption-notice', {
      headers: { 'X-aws-ec2-metadata-token': token }
    });
    if (res.status === 200) {
      console.log('SPOT INTERRUPTION DETECTED');
      shuttingDown = true;
    }
  } catch {}
}
setInterval(checkInterruption, 5000);

async function encodeVideo(jobId, s3Key) {
  const tmpDir = mkdtempSync(join(tmpdir(), 'encode-'));
  const inputPath = join(tmpDir, 'input.mp4');
  const outputDir = join(tmpDir, 'output');

  try {
    // Download do S3
    console.log(`[${jobId}] Downloading ${s3Key}`);
    const { Body } = await s3.send(new GetObjectCommand({ Bucket: INPUT_BUCKET, Key: s3Key }));
    const writeStream = createWriteStream(inputPath);
    await new Promise((resolve, reject) => {
      Body.pipe(writeStream).on('finish', resolve).on('error', reject);
    });

    // FFmpeg multi-bitrate HLS com GPU NVENC
    console.log(`[${jobId}] Encoding with NVENC...`);
    execSync(mkdtempSync, { stdio: 'inherit' });

    const ffmpegCmd = [
      'ffmpeg', '-y',
      '-hwaccel', 'cuda',
      '-hwaccel_output_format', 'cuda',
      '-i', inputPath,
      // 360p
      '-vf', 'scale_cuda=640:360', '-c:v', 'h264_nvenc', '-preset', 'p4', '-b:v', '400k', '-c:a', 'aac', '-b:a', '64k',
      '-hls_time', '6', '-hls_list_size', '0', '-f', 'hls', join(outputDir, '360p.m3u8'),
      // 720p
      '-vf', 'scale_cuda=1280:720', '-c:v', 'h264_nvenc', '-preset', 'p4', '-b:v', '2500k', '-c:a', 'aac', '-b:a', '128k',
      '-hls_time', '6', '-hls_list_size', '0', '-f', 'hls', join(outputDir, '720p.m3u8'),
      // 1080p
      '-vf', 'scale_cuda=1920:1080', '-c:v', 'h264_nvenc', '-preset', 'p4', '-b:v', '5000k', '-c:a', 'aac', '-b:a', '192k',
      '-hls_time', '6', '-hls_list_size', '0', '-f', 'hls', join(outputDir, '1080p.m3u8'),
    ];
    execSync(ffmpegCmd.join(' '), { stdio: 'inherit' });

    // Gera master playlist
    const masterPlaylist = `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=464000,RESOLUTION=640x360
360p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2628000,RESOLUTION=1280x720
720p.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5192000,RESOLUTION=1920x1080
1080p.m3u8`;

    // Upload para S3
    const outputPrefix = `encoded/${jobId}/`;
    console.log(`[${jobId}] Uploading to S3...`);
    // (upload de todos os arquivos do outputDir para S3 - simplificado)
    execSync(`aws s3 sync ${outputDir} s3://${OUTPUT_BUCKET}/${outputPrefix} --cache-control "public,max-age=31536000,immutable"`);
    await s3.send(new PutObjectCommand({
      Bucket: OUTPUT_BUCKET,
      Key: `${outputPrefix}index.m3u8`,
      Body: masterPlaylist,
      ContentType: 'application/x-mpegURL',
      CacheControl: 'public,max-age=10',
    }));

    return `${outputPrefix}index.m3u8`;
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

async function processJob(message) {
  const body = JSON.parse(message.Body);
  const { jobId, s3Key } = body;

  console.log(`[${jobId}] Starting encode for ${s3Key}`);

  const manifestKey = await encodeVideo(jobId, s3Key);

  // Publica evento de conclusão
  await sns.send(new PublishCommand({
    TopicArn: SNS_TOPIC,
    Message: JSON.stringify({ event: 'finished', jobId, manifestKey }),
    MessageAttributes: { event: { DataType: 'String', StringValue: 'finished' } },
  }));

  console.log(`[${jobId}] Done → ${manifestKey}`);
}

async function poll() {
  while (!shuttingDown) {
    const { Messages } = await sqs.send(new ReceiveMessageCommand({
      QueueUrl: QUEUE_URL,
      MaxNumberOfMessages: 1,
      WaitTimeSeconds: 20,
      VisibilityTimeout: 600,
    }));

    if (!Messages?.length) continue;
    const msg = Messages[0];

    try {
      await processJob(msg);
      await sqs.send(new DeleteMessageCommand({
        QueueUrl: QUEUE_URL,
        ReceiptHandle: msg.ReceiptHandle,
      }));
    } catch (err) {
      console.error('Job failed:', err);
      // Volta pra fila imediatamente (ou será deletado pelo DLQ após maxReceiveCount)
      await sqs.send(new ChangeMessageVisibilityCommand({
        QueueUrl: QUEUE_URL,
        ReceiptHandle: msg.ReceiptHandle,
        VisibilityTimeout: 0,
      }));
    }
  }

  console.log('Worker shutting down gracefully');
  process.exit(0);
}

poll().catch(console.error);
```

### 🧪 Lab 10.3 — Auto Scaling Group para workers GPU

```bash
# Launch template para g4dn.xlarge Spot
aws ec2 create-launch-template --launch-template-name encoder-gpu-lt \
  --launch-template-data '{
    "ImageId": "'$ENCODER_AMI'",
    "InstanceType": "g4dn.xlarge",
    "IamInstanceProfile": {"Name": "encoder-profile"},
    "SecurityGroupIds": ["'$SG_APP'"],
    "TagSpecifications": [{"ResourceType":"instance","Tags":[{"Key":"Project","Value":"streaming-learning"},{"Key":"Role","Value":"encoder"}]}],
    "UserData": "'$(base64 -w0 encoder-bootstrap.sh)'"
  }'

# Auto Scaling Group com Spot
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name encoder-asg \
  --launch-template "LaunchTemplateName=encoder-gpu-lt,Version=\$Latest" \
  --min-size 0 --max-size 10 --desired-capacity 0 \
  --vpc-zone-identifier "$PRIV_A,$PRIV_B" \
  --mixed-instances-policy '{
    "LaunchTemplate": {"LaunchTemplateSpecification":{"LaunchTemplateName":"encoder-gpu-lt","Version":"$Latest"}},
    "InstancesDistribution": {
      "OnDemandPercentageAboveBaseCapacity": 0,
      "SpotAllocationStrategy": "price-capacity-optimized",
      "SpotInstancePools": 2
    },
    "Overrides": [
      {"InstanceType":"g4dn.xlarge"},
      {"InstanceType":"g4dn.2xlarge"},
      {"InstanceType":"g5.xlarge"}
    ]
  }'
```

### 🧪 Lab 10.4 — Scale based on SQS queue depth

```bash
# Target Tracking: 1 instância por mensagem na fila (máx 10)
aws autoscaling put-scaling-policy --auto-scaling-group-name encoder-asg \
  --policy-name queue-depth-tracking \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "CustomizedMetricSpecification": {
      "MetricName": "ApproximateNumberOfMessagesVisible",
      "Namespace": "AWS/SQS",
      "Dimensions": [{"Name":"QueueName","Value":"encoder-jobs"}],
      "Statistic": "Average"
    },
    "TargetValue": 1.0,
    "DisableScaleIn": false
  }'
```

> Com isso, cada mensagem acumula ~1 instância GPU. Quando fila zera, ASG escala para 0 = **US$ 0** quando idle.

### 🧪 Lab 10.5 — Player HTML5 com HLS.js

```html
<!-- index.html no frontend NestJS -->
<video id="player" controls width="1280" height="720"></video>
<script src="https://cdn.jsdelivr.net/npm/hls.js@latest"></script>
<script>
const video = document.getElementById('player');
const manifestUrl = 'https://cdn.streaming.example.com/encoded/abc123/index.m3u8';

if (Hls.isSupported()) {
  const hls = new Hls();
  hls.loadSource(manifestUrl);
  hls.attachMedia(video);
} else if (video.canPlayType('application/vnd.apple.mpegurl')) {
  // Safari nativo
  video.src = manifestUrl;
}
</script>
```

---

## 4. MediaConvert como alternativa gerenciada

Se você preferir **não administrar EC2 GPU**, o AWS Elemental MediaConvert é a alternativa:

- Serviço gerenciado de transcodificação. Sem instâncias.
- Cria Job → MediaConvert lê S3 → grava S3.
- Custo: US$ 0.0075 / minuto de vídeo (1080p) até US$ 0.0195 (4K).
- Latência: filas compartilhadas podem ter delay.

**Comparação:**

| | EC2 GPU Spot | MediaConvert |
|---|-------------|--------------|
| Controle | Total (codecs, filtros) | Templates |
| Custo / min 1080p | ~US$ 0.002 (`g4dn.xlarge` spot ~10s/min vídeo) | US$ 0.0075 |
| Operação | Você gerencia | Serverless |
| Escala | Manual (ASG) | Automática |
| DRM nativo | DIY | Sim (SPEKE) |

> Para aprender, **comece com EC2 GPU** (total controle). Em produção com requisito de DRM, **avalie MediaConvert**.

---

## 5. DRM (opcional mas real em produção)

**FairPlay (Apple) + Widevine (Google) + PlayReady (Microsoft)** = trifecta de proteção.

- Chaves gerenciadas por serviço SPEKE (Secure Packager and Encoder Key Exchange).
- AWS MediaPackage integra nativo.
- Com EC2 + Shaka Packager: open-source, mais DIY.

> Fora do escopo do lab, mas saiba que existe. Em plataforma com conteúdo licenciado (filmes de estúdio), DRM é obrigatório.

---

## 6. Armadilhas e custos

| Armadilha | Impacto | Como evitar |
|-----------|---------|-------------|
| Encoding sem GPU | 10–30× mais lento + caro | Sempre `g4dn`+ NVENC |
| ASG sem scale-to-zero | EC2 GPU idle = US$ 380/mês | `min-size=0`, scaling por SQS depth |
| Encoding sem multipart | Upload grande de saída lento | `aws s3 sync` usa multipart |
| Segments sem Cache-Control imutável | CloudFront não cacheia | `max-age=31536000,immutable` nos `.ts` |
| Falta de interrupt handler | Job perdido ao Spot terminar | Detecta SIGTERM, muda VT=0 |
| Output em S3 Standard para originals | Caro para arquivar originals | Lifecycle → Glacier |
| Manifesto com TTL longo | Player usa playlist antiga após update | `max-age=10` no `.m3u8` |
| Falta de signed cookies | Vídeo acessível sem autenticação | CloudFront signed cookies obrigatório |

**Custos típicos para 1h de vídeo 1080p:**

- Download do original: S3 GET~US$ 0.
- Encoding em `g4dn.xlarge` spot (10min job): US$ 0.027.
- Upload dos segments HLS: S3 PUT ~US$ 0.01.
- Storage de segments HLS (5 qualidades ~3.5 GB): US$ 0.08/mês.
- Streaming para 1000 usuários simultâneos via CloudFront: ~US$ 85/TB.

---

## 7. Checklist de domínio

- [ ] Sei a diferença entre HLS e DASH e quando usar cada um.
- [ ] Entendo ABR e por que múltiplos bitrates.
- [ ] Sei instalar FFmpeg com suporte NVENC em EC2 GPU.
- [ ] Criei pipeline completo: S3 → SQS → Worker → S3 → CloudFront.
- [ ] ASG escala para 0 quando fila vazia.
- [ ] Worker tem spot interrupt handler.
- [ ] HLS player funcionando no browser.
- [ ] Manifesto com TTL curto, segments com TTL longo (imutável).
- [ ] Conteúdo protegido por CloudFront signed cookies.
- [ ] Sei calcular custo de encoding 1h de vídeo.

---

## 8. Recursos

**Ferramentas:**
- [FFmpeg docs](https://ffmpeg.org/documentation.html).
- [HLS.js](https://github.com/video-dev/hls.js) — player open-source.
- [Shaka Player](https://github.com/shaka-project/shaka-player) — player multi-formato Google.
- [Video.js](https://videojs.com/) — player configurável.
- [Bento4](https://www.bento4.com/) — packager DASH/HLS.

**Posts:**
- "AWS Media Services transcoding guide".
- "FFmpeg NVENC encoding guide" — trac.ffmpeg.org.
- "HLS encoding best practices" — Cloudflare Stream blog.

---

➡️ Próximo: **Módulo 11 — Terraform**.
