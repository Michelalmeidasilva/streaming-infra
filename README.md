# Infrastructure Setup

This directory contains the centralized infrastructure configuration for the Video on Demand platform. All services share a common Docker Compose configuration that spins up the required databases, message queues, and storage systems.

## Quick Start

Start all infrastructure services:

```bash
cd infra
docker compose up -d
```

Stop all services:

```bash
docker compose down
```

Stop and remove all data:

```bash
docker compose down -v
```

## Services Overview

### MongoDB
- **Port**: 27017
- **Username**: admin
- **Password**: password
- **Purpose**: Primary database for streaming events, metadata, and distribution
- **Used by**: streaming-ingest, streaming-distribution
- **Web UI**: http://localhost:8081 (Mongo Express - admin/password)

### RabbitMQ
- **AMQP Port**: 5672
- **Management UI Port**: 15672
- **Username**: guest
- **Password**: guest
- **Purpose**: Message broker for video processing pipeline
- **Web UI**: http://localhost:15672
- **Used by**: streaming-ingest (publisher), streaming-transcode (consumer), streaming-telemetry (consumer)

### Redis
- **Port**: 6379
- **Purpose**: Cache layer for streaming distribution and real-time data
- **Used by**: streaming-distribution
- **Persistence**: Enabled (AOF - Append Only File)

### MinIO
- **S3 API Port**: 9000
- **Console Port**: 9001
- **Access Key**: admin
- **Secret Key**: password123
- **Bucket**: videos (auto-created)
- **Purpose**: S3-compatible object storage for video files and assets
- **Web UI**: http://localhost:9001 (admin/password123)
- **Used by**: streaming-ingest, streaming-platform-upload
- **Webhook Configuration**: Automatically configured by minio-setup service

## Environment Variables for Applications

When running your services locally, use these environment variables to connect to the infrastructure:

```bash
# MongoDB
MONGODB_URI=mongodb://admin:password@localhost:27017/streaming?authSource=admin

# RabbitMQ
RABBITMQ_URL=amqp://guest:guest@localhost:5672/

# Redis
REDIS_URL=redis://localhost:6379

# MinIO / S3 (local development)
STORAGE_PROVIDER=minio
STORAGE_BUCKET=videos
MINIO_ENDPOINT=http://localhost:9000
MINIO_ACCESS_KEY=admin
MINIO_SECRET_KEY=password123

# MinIO / S3 (when running from within Docker container)
MINIO_ENDPOINT=http://minio:9000
```

## Service Dependencies

```
streaming-ingest
  ├── MongoDB (metadata, events)
  ├── RabbitMQ (publish video_events)
  └── MinIO (webhook source for video uploads)

streaming-platform-upload
  └── MinIO (upload video files)

streaming-transcode
  └── RabbitMQ (consume transcoding jobs from video_events queue)

streaming-distribution
  ├── MongoDB (manifests, metadata)
  └── Redis (cache layer)

streaming-telemetry
  └── RabbitMQ (consume analytics events from video_events queue)
```

## Connecting from Host Machine vs Docker

### From Host Machine (Local Development)
```bash
mongodb://admin:password@localhost:27017/?authSource=admin
amqp://guest:guest@localhost:5672
redis://localhost:6379
http://localhost:9000  # MinIO
```

### From Docker Container (Service Running in Docker)
```bash
mongodb://admin:password@mongodb:27017/?authSource=admin
amqp://guest:guest@rabbitmq:5672
redis://redis:6379
http://minio:9000  # MinIO
```

The services are connected via a shared Docker network: `vod-network`

## Health Checks

Each service includes a health check. View the status:

```bash
docker compose ps
```

Expected output:
```
CONTAINER ID   IMAGE                          STATUS              PORTS
...
mongodb        mongo:7                        Up ... (healthy)    27017/tcp
rabbitmq       rabbitmq:3.13-management      Up ... (healthy)    5672/tcp, 15672/tcp
redis          redis:7-alpine                Up ... (healthy)    6379/tcp
minio          minio/minio:latest            Up ... (healthy)    9000/tcp, 9001/tcp
mongo-express  mongo-express:latest          Up ...              8081/tcp
minio-setup    minio/mc:latest               Exited (0)          -
```

## Troubleshooting

### MinIO Bucket Not Created
If the `minio-setup` service fails, manually create the bucket:

```bash
docker exec minio mc alias set local http://localhost:9000 admin password123
docker exec minio mc mb local/videos
```

### Connection Refused
Ensure all services are healthy:
```bash
docker compose ps
docker compose logs -f
```

### Reset Everything
To start fresh with a clean state:

```bash
docker compose down -v
docker compose up -d
```

This will remove all volumes and recreate them fresh.

## Production Considerations

**Do not use this configuration in production**. For production deployments:

1. Use managed services (AWS RDS for MongoDB, AWS MQ for RabbitMQ, etc.)
2. Change default credentials to strong, unique passwords
3. Enable TLS/SSL for all connections
4. Configure proper backup and disaster recovery strategies
5. Set up monitoring and alerting
6. Use proper networking and security groups
7. Configure rate limiting and request throttling

## Notes

- The infrastructure uses `unless-stopped` restart policy, so containers will restart after Docker daemon restarts, but won't start if manually stopped
- All data is persisted in Docker volumes
- The services communicate through the `vod-network` Docker network
- Ports are exposed to localhost for local development convenience
