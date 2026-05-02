# Quick Start Guide

## 1. Start the Infrastructure

```bash
cd infra
docker compose up -d
```

## 2. Verify All Services Are Running

```bash
docker compose ps
```

Expected output:
```
NAME            IMAGE                          STATUS              PORTS
mongodb         mongo:7                        Up 10s (healthy)    27017/tcp
rabbitmq        rabbitmq:3.13-management      Up 15s (healthy)    5672/tcp, 15672/tcp
redis           redis:7-alpine                Up 8s (healthy)     6379/tcp
minio           minio/minio:latest            Up 12s (healthy)    9000/tcp, 9001/tcp
minio-setup     minio/mc:latest               Exited (0)          -
mongo-express   mongo-express:latest          Up 5s               8081/tcp
```

## 3. Access Web UIs

| Service | URL | Username | Password |
|---------|-----|----------|----------|
| Mongo Express | http://localhost:8081 | admin | password |
| RabbitMQ Management | http://localhost:15672 | guest | guest |
| MinIO Console | http://localhost:9001 | admin | password123 |

## 4. Run Your Applications

Each service can be run locally. Use the environment variables from `infra/.env.example`:

### Option A: Copy and Use .env

```bash
cp infra/.env.example .env
```

Then each service can load from the .env file:

```bash
# In streaming-ingest
source ../../.env
go run cmd/api/main.go

# In streaming-platform-upload
source ../../.env
npm run dev

# In streaming-transcode
source ../../.env
bash pipeline.sh

# In streaming-distribution
source ../../.env
go run cmd/api/main.go
```

### Option B: Set Variables Inline

```bash
# streaming-ingest
export MONGODB_URI=mongodb://admin:password@localhost:27017/streaming?authSource=admin
export RABBITMQ_URL=amqp://guest:guest@localhost:5672/
export MINIO_ENDPOINT=http://localhost:9000
export MINIO_ROOT_USER=admin
export MINIO_ROOT_PASSWORD=password123
cd streaming-ingest && docker compose up --build
```

## 5. Test the Upload Flow

### 5.1 Verify MinIO Setup

```bash
# Check that the videos bucket exists
docker exec minio mc ls local/videos
```

Expected:
```
[2026-04-27 22:45:34 UTC]     0B videos/
```

### 5.2 Test MongoDB Connection

```bash
# Using mongo CLI
mongosh "mongodb://admin:password@localhost:27017/?authSource=admin"

# In mongo shell:
use streaming
db.upload_events.insertOne({
  video_id: "test-001",
  status: "started",
  filename: "test.mp4",
  created_at: new Date()
})

db.upload_events.findOne()
```

### 5.3 Test RabbitMQ Connection

Open http://localhost:15672 and log in with guest/guest

Expected:
- Overview shows: 1 connection, 0 channels, 0 queues (initially)
- After services start, you'll see the queues created

## 6. Common Workflows

### Upload and Transcode a Video

```bash
# 1. Start infra
cd infra && docker compose up -d

# 2. Start streaming-ingest (handles webhooks)
cd streaming-ingest && docker compose up --build

# 3. Upload a video via streaming-platform-upload
cd streaming-platform-upload
npm install && npm run dev
# Open http://localhost:3000 and upload a video

# 4. Start streaming-transcode (processes the queued job)
cd streaming-transcode
bash pipeline.sh  # Will transcode any videos in the raw folder

# 5. View results
# Transcoded segments in: MinIO console http://localhost:9001 → videos/transcoded
# Job status in: Mongo Express http://localhost:8081 → streaming → transcoding_jobs
```

### Monitor Events in Real-Time

```bash
# Watch MongoDB for new upload events
docker exec mongodb mongosh "mongodb://admin:password@localhost:27017/streaming?authSource=admin" \
  --eval "db.upload_events.find().watch()" --eval "while(true) { sleep(1000) }"

# Watch RabbitMQ queue depth
docker exec rabbitmq rabbitmqctl list_queues name messages consumers
```

### Debug a Failed Upload

1. **Check Mongo Express**: http://localhost:8081
   - Navigate to `streaming.upload_events`
   - Look for entries with `status: "failed"`
   - Check the `error_message` field

2. **Check Logs**:
   ```bash
   docker compose logs streaming-ingest | tail -100
   docker compose logs rabbitmq | tail -50
   ```

3. **Inspect RabbitMQ**:
   - Visit http://localhost:15672
   - Click "Queues"
   - Check for messages in `transcoding_queue`
   - Click queue → "Get Message" to inspect payload

### Clean Start

```bash
# Stop and remove everything (including data)
docker compose down -v

# Restart
docker compose up -d
```

## 7. Environment Variables Quick Reference

| Variable | Local Value | Docker Value | Purpose |
|----------|-------------|--------------|---------|
| `MONGODB_URI` | `mongodb://admin:password@localhost:27017/streaming?authSource=admin` | `mongodb://admin:password@mongodb:27017/streaming?authSource=admin` | Database connection |
| `RABBITMQ_URL` | `amqp://guest:guest@localhost:5672/` | `amqp://guest:guest@rabbitmq:5672/` | Message broker |
| `REDIS_URL` | `redis://localhost:6379` | `redis://redis:6379` | Cache layer |
| `MINIO_ENDPOINT` | `http://localhost:9000` | `http://minio:9000` | Object storage |

**Rule**: Use `localhost` when running services on your host machine, use service names (mongodb, rabbitmq, etc) when running services inside Docker containers.

## Troubleshooting

### Port Already in Use

If a port is already in use, modify `docker-compose.yml`:

```yaml
mongodb:
  ports:
    - "27018:27017"  # host:container (change 27018 to any available port)
```

Then update your connection strings accordingly.

### Services Not Healthy

Check logs:
```bash
docker compose logs -f
```

Restart a specific service:
```bash
docker compose restart mongodb
```

### Connection Refused

Ensure Docker is running and all services are healthy:
```bash
docker compose ps
docker compose up -d --build
```

### Cannot Create Bucket in MinIO

The bucket should be auto-created by `minio-setup`. If not:

```bash
docker exec minio mc alias set local http://localhost:9000 admin password123
docker exec minio mc mb local/videos
```

## Next Steps

1. **Read INFRASTRUCTURE.md** for detailed architecture information
2. **Check each service's SPEC.md** for API contracts
3. **Review streaming-ingest/PIPELINE.md** for the transcode workflow
4. **Start developing!** Use the environment variables above when running services locally
