# Infrastructure Architecture

## Overview

The VOD platform infrastructure consists of four main components that support the microservices architecture:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Application Layer                            │
├─────────────────────────────────────────────────────────────────┤
│  streaming-platform-upload  │  streaming-ingest  │ streaming... │
├─────────────────────────────────────────────────────────────────┤
│              Infrastructure Layer (Docker Compose)               │
├──────────────┬──────────────┬──────────────┬─────────────────────┤
│  MongoDB     │  RabbitMQ    │  Redis       │  MinIO              │
│  (Database)  │  (Messaging) │  (Cache)     │  (Object Storage)   │
└──────────────┴──────────────┴──────────────┴─────────────────────┘
```

## Component Details

### 1. MongoDB (Data Layer)

**Role**: Primary persistent database for the platform

**Collections**:
- `upload_events`: Tracks video upload lifecycle (started, progress, completed, failed)
- `transcoding_jobs`: Manages transcode job state and metadata
- `manifests`: Stores HLS/DASH manifest information
- `distribution_metadata`: CDN and edge location metadata
- `telemetry`: Logs and metrics from all services

**Schema Relationships**:
```
upload_events
  ├── created_at (indexed for range queries)
  ├── video_id (indexed for fast lookups)
  └── status: "started" | "uploading" | "completed" | "failed"

transcoding_jobs
  ├── video_id (foreign key to upload_events)
  ├── renditions: [360p, 480p, 720p, 1080p]
  └── status: "pending" | "in_progress" | "completed" | "failed"

manifests
  ├── video_id
  ├── hls_url (playback URL for HLS)
  └── dash_url (playback URL for DASH)
```

**Connection Pattern**:
```
Services → MongoDB (reads/writes)
           ↓
           Indexing (O(log n) lookups)
           ↓
           Persistence (AOF-like durability)
```

**Typical Queries**:
```javascript
// streaming-ingest writes upload events
db.upload_events.insertOne({
  video_id: "uuid",
  status: "started",
  size_mb: 500,
  created_at: new Date()
})

// streaming-distribution reads manifests
db.manifests.findOne({ video_id: "uuid" })

// streaming-transcode updates job status
db.transcoding_jobs.updateOne(
  { _id: job_id },
  { $set: { status: "completed", completed_at: new Date() } }
)
```

### 2. RabbitMQ (Message Queue)

**Role**: Event broker connecting upload → transcoding → distribution

**Topic Exchange**: `video_events`

**Routing Keys and Queues**:
```
video_events (Topic Exchange)
  │
  ├─ Routing Key: video.upload.* 
  │  └─ Queue: transcoding_queue → streaming-transcode
  │
  ├─ Routing Key: video.transcode.completed
  │  └─ Queue: distribution_queue → streaming-distribution
  │
  └─ Routing Key: video.*.*
     └─ Queue: telemetry_queue → streaming-telemetry
```

**Event Flow**:
```
1. streaming-ingest publishes:
   Topic: video_events
   RoutingKey: video.upload.started
   {
     "video_id": "uuid",
     "filename": "movie.mp4",
     "size_bytes": 500000000,
     "timestamp": "2026-04-27T10:00:00Z"
   }

2. streaming-transcode consumes from transcoding_queue:
   - FFmpeg converts to H.264
   - shaka-packager creates HLS/DASH segments
   - Uploads results to MinIO
   - Publishes video.transcode.completed event

3. streaming-distribution consumes from distribution_queue:
   - Generates CDN manifest URLs
   - Caches in Redis
   - Updates MongoDB with manifest locations

4. streaming-telemetry consumes from telemetry_queue:
   - Aggregates metrics
   - Stores in telemetry collection
```

**Queue Configuration**:
- **Durable**: Yes (survives broker restarts)
- **Auto-delete**: No (persists until explicitly deleted)
- **Max retries**: Application-defined (typically 3)
- **TTL**: 7 days (events expire if not processed)

**Connection Pattern**:
```
streaming-ingest (publisher)
  └─ Publishes to video_events
       ↓
   routing based on key
       ↓
   ├─ transcoding_queue → streaming-transcode (consumer)
   ├─ distribution_queue → streaming-distribution (consumer)
   └─ telemetry_queue → streaming-telemetry (consumer)
```

### 3. Redis (Cache Layer)

**Role**: In-memory cache for high-frequency reads and real-time state

**Data Structures**:
```
Key Patterns:

1. Manifest Cache (TTL: 1 hour)
   Key: manifest:{video_id}:hls
   Value: JSON manifest object
   
   Key: manifest:{video_id}:dash
   Value: JSON manifest object

2. Transcode Job Status (TTL: 24 hours)
   Key: transcode_job:{job_id}:progress
   Value: { "status": "in_progress", "percent": 45 }

3. Video Metadata (TTL: 30 days)
   Key: video:{video_id}:metadata
   Value: { "title": "...", "duration": 3600, "size_mb": 500 }

4. Real-time Counters
   Key: video:{video_id}:views
   Value: Incremented on each view

5. Session Cache
   Key: session:{session_id}
   Value: { user_id, token, expires_at }
```

**Persistence Strategy**:
- **RDB** (disabled by default)
- **AOF** (Append Only File) - enabled
- Snapshots every 1 minute (configurable)

**Eviction Policy**: `allkeys-lru` (least recently used)

**Connection Pattern**:
```
streaming-distribution (client)
  └─ GET manifest:{video_id}:hls
       ↓
   Cache hit: Return instantly (µs)
       or
   Cache miss: Query MongoDB, cache result, return
```

### 4. MinIO (Object Storage)

**Role**: S3-compatible storage for video files, transcoded segments, and CDN artifacts

**Bucket Structure**:
```
videos/                          (primary bucket)
  ├── raw/
  │   ├── {video_id}/
  │   │   └── original.mp4
  │   └── {video_id}/
  │       └── original.mov
  │
  ├── transcoded/
  │   ├── {video_id}/360p/
  │   │   ├── segment-0.m4s
  │   │   ├── segment-1.m4s
  │   │   └── init.mp4
  │   ├── {video_id}/480p/
  │   ├── {video_id}/720p/
  │   └── {video_id}/1080p/
  │
  └── manifests/
      ├── {video_id}.m3u8       (HLS)
      └── {video_id}.mpd        (DASH)
```

**Webhook Configuration**:
```
Event: ObjectCreated (s3:ObjectCreated:*)
Endpoint: http://streaming-ingest:8080/api/v1/webhooks/storage/minio
Routing Key: minio/videos
```

**Upload Flow**:
```
streaming-platform-upload
  └─ PutObject: videos/raw/{video_id}/original.mp4
       ↓
   MinIO webhook triggers
       ↓
   POST /api/v1/webhooks/storage/minio
       └─ streaming-ingest processes
           └─ Publishes to RabbitMQ
```

## Data Flow Diagrams

### Complete Upload → Playback Pipeline

```
┌──────────────────────────────────────┐
│ streaming-platform-upload (Next.js)  │
│ - User uploads video                 │
│ - 10MB chunks via multipart           │
└──────────────────────────────────────┘
                  │
                  ├─► POST /api/v1/events (initiate)
                  │   └─► MongoDB: insert upload_event
                  │
                  ├─► MinIO: PutObject (10MB chunks)
                  │   └─► Completes multipart upload
                  │
                  └─► POST /api/v1/events (complete)
                      └─► MongoDB: update upload_event

                        │
                        ▼
         ┌─────────────────────────┐
         │  MinIO Webhook Trigger  │
         │  (ObjectCreated event)  │
         └─────────────────────────┘
                        │
                        ▼
        ┌──────────────────────────────────┐
        │   streaming-ingest (Go/Fiber)    │
        │ - Receive webhook                │
        │ - Extract video_id, size, type   │
        │ - Publish to RabbitMQ            │
        └──────────────────────────────────┘
                        │
                        ▼
              ┌─────────────────────┐
              │   RabbitMQ Topic    │
              │  video.upload.*     │
              └─────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
   transcoding_    distribution_    telemetry_
      queue          queue            queue
        │               │               │
        ▼               ▼               ▼
   streaming-        streaming-    streaming-
   transcode        distribution   telemetry
        │               │               │
        ├─► FFmpeg      ├─► Redis      ├─► MongoDB
        ├─► shaka-pkg   ├─► MongoDB    └─► Logging
        └─► MinIO       └─► CDN
             (upload       manifest
             segments)     URLs)
```

### Connection Matrix

| From | To | Protocol | Purpose |
|------|-------|----------|---------|
| streaming-ingest | MongoDB | TCP:27017 | Event persistence |
| streaming-ingest | RabbitMQ | AMQP:5672 | Publish video events |
| streaming-ingest | MinIO | S3:9000 | Webhook source |
| streaming-platform-upload | MinIO | S3:9000 | Upload video files |
| streaming-transcode | RabbitMQ | AMQP:5672 | Consume transcode jobs |
| streaming-transcode | MinIO | S3:9000 | Upload transcoded segments |
| streaming-transcode | MongoDB | TCP:27017 | Update job status |
| streaming-distribution | MongoDB | TCP:27017 | Read manifests |
| streaming-distribution | Redis | TCP:6379 | Cache manifests |
| streaming-telemetry | RabbitMQ | AMQP:5672 | Consume events |
| streaming-telemetry | MongoDB | TCP:27017 | Store telemetry |

## Scaling Considerations

### Horizontal Scaling

**RabbitMQ**:
- Multiple consumers can read from the same queue (load balanced)
- Implement consumer groups for streaming-transcode (process multiple videos in parallel)

**Redis**:
- Implement Redis Cluster for sharding large datasets
- Use Redis Sentinel for high availability

**MongoDB**:
- Implement replica sets for high availability
- Use sharding for large collections (e.g., telemetry with millions of events)
- Create indexes on frequently queried fields

**MinIO**:
- Deploy as MinIO Cluster (distributed) for high availability
- Use object locking for compliance

### Performance Optimization

1. **Database Indexing**:
   ```javascript
   db.upload_events.createIndex({ video_id: 1, created_at: -1 })
   db.transcoding_jobs.createIndex({ status: 1, created_at: -1 })
   ```

2. **Connection Pooling**:
   - MongoDB: Connection pool size = 50-100
   - Redis: Connection pool size = 10-20
   - RabbitMQ: Channel pool size = num_consumers * 2

3. **Batch Operations**:
   - Use bulk inserts for telemetry events
   - Batch manifest updates before pushing to CDN

## Disaster Recovery

### Backup Strategy

```
# Automated daily MongoDB backup
mongodump --uri "mongodb://admin:password@localhost:27017/streaming?authSource=admin" \
  --out /backups/mongo-$(date +%Y%m%d)

# Automated MinIO backup (mirror to S3)
mc mirror minio/videos s3://backup-bucket/videos

# Redis persistence (AOF)
# Already configured in docker-compose.yml
```

### Recovery Procedures

**MongoDB Recovery**:
```bash
mongorestore --uri "mongodb://admin:password@localhost:27017/?authSource=admin" \
  /backups/mongo-20260427
```

**MinIO Recovery**:
```bash
mc mirror s3://backup-bucket/videos minio/videos
```

**Complete Infrastructure Reset**:
```bash
docker compose down -v
docker compose up -d
# Services will reinitialize with default buckets/databases
```
