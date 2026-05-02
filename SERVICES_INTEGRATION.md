# Services Integration Guide

This guide explains how each microservice connects to the centralized infrastructure.

## Prerequisites

All infrastructure must be running before starting services:

```bash
cd infra
docker compose up -d
docker compose ps  # verify all services are healthy
```

## streaming-ingest (Go / Event Gateway)

**Role**: Receives webhooks, publishes events to RabbitMQ, stores metadata in MongoDB

### Required Environment Variables

```bash
RABBITMQ_URL=amqp://guest:guest@localhost:5672/
MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
SERVER_PORT=8080
MINIO_ENDPOINT=http://localhost:9000
MINIO_ROOT_USER=admin
MINIO_ROOT_PASSWORD=password123
```

### Setup Steps

1. **Configure environment**:
   ```bash
   cd streaming-ingest
   export RABBITMQ_URL=amqp://guest:guest@localhost:5672/
   export MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
   export MINIO_ENDPOINT=http://localhost:9000
   export MINIO_ROOT_USER=admin
   export MINIO_ROOT_PASSWORD=password123
   ```

2. **Start the service**:
   ```bash
   # Using Docker Compose
   docker compose up --build
   
   # OR using local Go toolchain
   go run cmd/api/main.go
   ```

3. **Verify it's running**:
   ```bash
   curl http://localhost:8080/health
   ```

### Connection Flow

```
MinIO (webhook source)
  └─ POST /api/v1/webhooks/storage/minio
     └─ streaming-ingest (processes webhook)
        ├─ Validates video metadata
        ├─ Stores in MongoDB (upload_events collection)
        └─ Publishes to RabbitMQ (video_events topic)
```

### Testing

```bash
# Check MongoDB events
mongosh "mongodb://admin:password@localhost:27017/streaming" \
  --eval "db.upload_events.find().pretty()"

# Check RabbitMQ queues
# Visit http://localhost:15672 → Queues tab
```

---

## streaming-platform-upload (Next.js / TypeScript)

**Role**: Provides UI for users to upload videos, handles multipart uploads to MinIO

### Required Environment Variables

```bash
STORAGE_PROVIDER=minio
STORAGE_BUCKET=videos
MINIO_ENDPOINT=http://localhost:9000
MINIO_ACCESS_KEY=admin
MINIO_SECRET_KEY=password123
```

### Setup Steps

1. **Copy environment file**:
   ```bash
   cd streaming-platform-upload
   cp .env.example .env.local
   ```

   Or manually set:
   ```bash
   export STORAGE_PROVIDER=minio
   export STORAGE_BUCKET=videos
   export MINIO_ENDPOINT=http://localhost:9000
   export MINIO_ACCESS_KEY=admin
   export MINIO_SECRET_KEY=password123
   ```

2. **Start the development server**:
   ```bash
   npm install
   npm run dev
   ```

3. **Access the UI**:
   - Navigate to http://localhost:3000
   - Upload a video file

### Connection Flow

```
Browser (streaming-platform-upload)
  └─ POST /api/upload/initiate
     ├─ Returns multipart upload ID
     └─ Browser sends 10MB chunks
        └─ POST /api/upload/chunk
           └─ MinIO stores chunks
              └─ Browser sends more chunks until complete
                 └─ POST /api/upload/complete
                    └─ MinIO finalizes multipart upload
                       └─ MinIO webhook triggers (ObjectCreated)
```

### Testing

```bash
# Upload a test video via the UI
# Then check MinIO:
open http://localhost:9001
# Navigate to: videos → raw → {video_id} → original.mp4

# Or via CLI:
docker exec minio mc ls local/videos/raw
```

---

## streaming-transcode (FFmpeg + shaka-packager)

**Role**: Consumes transcode jobs from RabbitMQ, outputs HLS/DASH segments to MinIO

### Required Environment Variables

```bash
RABBITMQ_URL=amqp://guest:guest@localhost:5672/
MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
MINIO_ENDPOINT=http://localhost:9000
MINIO_ACCESS_KEY=admin
MINIO_SECRET_KEY=password123
```

### Prerequisites

- FFmpeg installed locally
- shaka-packager installed locally

### Setup Steps

1. **Configure environment**:
   ```bash
   cd streaming-transcode
   export RABBITMQ_URL=amqp://guest:guest@localhost:5672/
   export MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
   export MINIO_ENDPOINT=http://localhost:9000
   export MINIO_ACCESS_KEY=admin
   export MINIO_SECRET_KEY=password123
   ```

2. **Start consuming from RabbitMQ** (use the pipeline script):
   ```bash
   # The PIPELINE.md file has ready-to-run commands
   bash pipeline.sh
   ```

   This script will:
   - Download videos from MinIO (`videos/raw/{video_id}/`)
   - Transcode to multiple renditions (360p, 480p, 720p, 1080p)
   - Package with shaka-packager into HLS/DASH segments
   - Upload segments to MinIO (`videos/transcoded/{video_id}/{resolution}/`)

3. **Verify processing**:
   ```bash
   # Check job status in MongoDB
   mongosh "mongodb://admin:password@localhost:27017/streaming" \
     --eval "db.transcoding_jobs.find().pretty()"
   
   # Check transcoded segments in MinIO
   docker exec minio mc ls local/videos/transcoded
   ```

### Connection Flow

```
RabbitMQ (video.upload.* events)
  └─ streaming-transcode consumes
     ├─ Downloads raw video from MinIO
     ├─ Runs FFmpeg transcoding
     ├─ Runs shaka-packager for HLS/DASH
     ├─ Uploads segments to MinIO
     └─ Updates MongoDB (transcoding_jobs.status = "completed")
        └─ Publishes video.transcode.completed event
           └─ streaming-distribution consumes
```

### Testing

```bash
# Monitor RabbitMQ queue
# Visit http://localhost:15672 → Queues → transcoding_queue

# Check MinIO for transcoded files
open http://localhost:9001
# videos → transcoded → {video_id} → 360p, 480p, 720p, 1080p

# Verify manifest files were created
docker exec minio mc ls local/videos/manifests
```

---

## streaming-distribution (Go / Distribution Service)

**Role**: Serves manifest URLs to consumers, caches in Redis, reads from MongoDB

### Required Environment Variables

```bash
MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
REDIS_URL=redis://localhost:6379
MINIO_ENDPOINT=http://localhost:9000
MINIO_ACCESS_KEY=admin
MINIO_SECRET_KEY=password123
SERVER_PORT=8082
```

### Setup Steps

1. **Configure environment**:
   ```bash
   cd streaming-distribution
   export MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
   export REDIS_URL=redis://localhost:6379
   export MINIO_ENDPOINT=http://localhost:9000
   export MINIO_ACCESS_KEY=admin
   export MINIO_SECRET_KEY=password123
   ```

2. **Start the service**:
   ```bash
   # Using Docker Compose
   docker compose up --build
   
   # OR using local Go toolchain
   go run cmd/api/main.go
   ```

3. **Verify it's running**:
   ```bash
   curl http://localhost:8082/health
   ```

### Connection Flow

```
Client (streaming-web-client / streaming-app-client)
  └─ GET /api/v1/manifests/{video_id}
     ├─ Check Redis cache
     │  ├─ Cache hit: Return cached manifest URL
     │  └─ Cache miss: Query MongoDB
     └─ MongoDB query
        ├─ Return manifest URL
        └─ Store in Redis (TTL: 1 hour)
           └─ Return to client
```

### Testing

```bash
# Get manifest for a video
curl http://localhost:8082/api/v1/manifests/{video_id}

# Check Redis cache
docker exec redis redis-cli
# In Redis CLI:
> KEYS manifest:*
> GET manifest:{video_id}:hls

# Check MongoDB
mongosh "mongodb://admin:password@localhost:27017/streaming" \
  --eval "db.manifests.find().pretty()"
```

---

## streaming-telemetry (Analytics Service)

**Role**: Consumes all events from RabbitMQ, aggregates metrics in MongoDB

### Required Environment Variables

```bash
RABBITMQ_URL=amqp://guest:guest@localhost:5672/
MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
```

### Setup Steps

1. **Configure environment**:
   ```bash
   cd streaming-telemetry
   export RABBITMQ_URL=amqp://guest:guest@localhost:5672/
   export MONGODB_URI=mongodb://admin:password@localhost:27017/streaming
   ```

2. **Start the service**:
   ```bash
   # Based on your service stack (Node, Go, Python, etc.)
   # Refer to streaming-telemetry/SPEC.md for specific instructions
   ```

### Connection Flow

```
RabbitMQ (video.*.* events)
  └─ streaming-telemetry consumes
     ├─ Processes video.upload.started
     ├─ Processes video.upload.completed
     ├─ Processes video.transcode.completed
     └─ Aggregates and stores in MongoDB
        └─ telemetry collection
```

---

## streaming-web-client (Svelte + PWA)

**Role**: Provides web UI for consumers to watch videos

### Required Environment Variables

```bash
VITE_DISTRIBUTION_API=http://localhost:8082
VITE_UPLOAD_API=http://localhost:3000
```

### Setup Steps

1. **Configure environment**:
   ```bash
   cd streaming-web-client
   export VITE_DISTRIBUTION_API=http://localhost:8082
   export VITE_UPLOAD_API=http://localhost:3000
   ```

2. **Start the dev server**:
   ```bash
   npm install
   npm run dev
   ```

3. **Access the app**:
   - Navigate to http://localhost:5173 (or the port shown in terminal)

### Connection Flow

```
Web Client (Svelte)
  ├─ GET /api/v1/manifests/{video_id} → streaming-distribution
  │  └─ Returns HLS/DASH manifest URL
  └─ Player (HLS.js / Dash.js)
     └─ Fetches segments from CDN/MinIO
        └─ Plays video
```

---

## streaming-app-client (React Native)

**Role**: Provides mobile UI for consumers to watch videos

### Required Environment Variables

```bash
REACT_APP_DISTRIBUTION_API=http://localhost:8082
REACT_APP_UPLOAD_API=http://localhost:3000
```

### Setup Steps

Similar to streaming-web-client, but for React Native:

```bash
cd streaming-app-client
npm install
npm run android  # or npm run ios
```

---

## Complete Flow Diagram

```
┌─────────────────────────────────┐
│ streaming-platform-upload       │
│ (3000) - Upload Videos          │
└────────────┬────────────────────┘
             │
             ├──► MinIO (9000)
             │    └─► ObjectCreated webhook
             │
             └─► streaming-ingest (8080)
                  │
                  ├──► MongoDB (27017)
                  └──► RabbitMQ (5672)
                       │
                       ├─► Queue: transcoding_queue
                       │   └─► streaming-transcode
                       │        └─ Download from MinIO
                       │        └─ FFmpeg + shaka-packager
                       │        └─ Upload to MinIO
                       │        └─ Update MongoDB
                       │
                       ├─► Queue: distribution_queue
                       │   └─► streaming-distribution (8082)
                       │        └─ Read from MongoDB
                       │        └─ Cache in Redis (6379)
                       │        └─ Serve manifest URLs
                       │
                       └─► Queue: telemetry_queue
                           └─► streaming-telemetry
                                └─ Aggregate in MongoDB

┌────────────────────────────────────────┐
│ streaming-web-client (5173)            │
│ streaming-app-client                   │
│ (Consumers - Play Videos)              │
└────────────┬───────────────────────────┘
             │
             └──► streaming-distribution (8082)
                  └─► GET /api/v1/manifests/{video_id}
                      └─ Redis cache or MongoDB lookup
                      └─ Return HLS/DASH manifest URL
                      └─ Client plays via manifest
```

## Debugging Checklist

### Services Won't Connect

1. **Check infra is running**:
   ```bash
   cd infra && docker compose ps
   ```

2. **Verify environment variables**:
   ```bash
   env | grep -E "MONGO|RABBIT|REDIS|MINIO"
   ```

3. **Test individual services**:
   ```bash
   make test-all  # from infra directory
   ```

### Videos Not Processing

1. **Check upload succeeded**:
   - Verify file in MinIO: http://localhost:9001/videos/raw

2. **Check webhook triggered**:
   - View streaming-ingest logs for webhook POST

3. **Check RabbitMQ queue**:
   - Visit http://localhost:15672 → Queues → transcoding_queue

4. **Check MongoDB for job**:
   ```bash
   mongosh "mongodb://admin:password@localhost:27017/streaming" \
     --eval "db.transcoding_jobs.findOne()"
   ```

### Manifests Not Available

1. **Check MongoDB for manifest entry**:
   ```bash
   mongosh "mongodb://admin:password@localhost:27017/streaming" \
     --eval "db.manifests.findOne()"
   ```

2. **Check Redis cache**:
   ```bash
   docker exec redis redis-cli GET "manifest:{video_id}:hls"
   ```

3. **Check distribution service is running**:
   ```bash
   curl http://localhost:8082/health
   ```

## Summary

| Service | Port | Role | Dependencies |
|---------|------|------|--------------|
| streaming-platform-upload | 3000 | Upload UI | MinIO |
| streaming-ingest | 8080 | Event Gateway | MongoDB, RabbitMQ, MinIO |
| streaming-transcode | - | Transcoding | RabbitMQ, MongoDB, MinIO |
| streaming-distribution | 8082 | Manifest Server | MongoDB, Redis, MinIO |
| streaming-telemetry | - | Analytics | RabbitMQ, MongoDB |
| streaming-web-client | 5173 | Playback UI | streaming-distribution |
| streaming-app-client | - | Mobile App | streaming-distribution |

All infrastructure services are defined in `infra/docker-compose.yml` and started with `docker compose up -d`.
