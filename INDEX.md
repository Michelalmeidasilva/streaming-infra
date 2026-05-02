# Infrastructure Documentation Index

This directory contains all infrastructure configuration and documentation for the Video on Demand platform. Start here to understand how to set up and use the infrastructure.

## Quick Links

- **👀 New to the infra?** → Start with [QUICKSTART.md](QUICKSTART.md)
- **⚙️ Setting up your service?** → Read [SERVICES_INTEGRATION.md](SERVICES_INTEGRATION.md)
- **🏗️ Understanding the architecture?** → See [INFRASTRUCTURE.md](INFRASTRUCTURE.md)
- **📋 Full service details?** → Check [README.md](README.md)
- **⌨️ Need a command shortcut?** → Use [Makefile](Makefile)

## Files in This Directory

### Configuration Files

| File | Purpose |
|------|---------|
| [`docker-compose.yml`](docker-compose.yml) | **Main file** - Contains all infrastructure services (MongoDB, RabbitMQ, Redis, MinIO) |
| [`.env.example`](.env.example) | Environment variables template for connecting to infrastructure |

### Documentation Files

| File | For Whom | Key Topics |
|------|----------|-----------|
| [**QUICKSTART.md**](QUICKSTART.md) | Everyone | How to start infra, verify services, access UIs, test connections |
| [**README.md**](README.md) | DevOps, Platform Engineers | Service overview, ports, credentials, troubleshooting, health checks |
| [**INFRASTRUCTURE.md**](INFRASTRUCTURE.md) | Architects, Senior Developers | Detailed architecture, data flows, MongoDB schemas, RabbitMQ routing, scaling |
| [**SERVICES_INTEGRATION.md**](SERVICES_INTEGRATION.md) | Application Developers | How to connect each service, environment variables, connection flows |
| [**Makefile**](Makefile) | Everyone | Common commands (make up, make down, make test-all, etc.) |
| [**INDEX.md**](INDEX.md) | You are here | Navigation guide to all documentation |

## Getting Started (30 seconds)

```bash
# 1. Start infrastructure
cd infra
docker compose up -d

# 2. Verify all services are healthy
make ps
make test-all

# 3. Access web UIs
# Mongo Express:    http://localhost:8081 (admin/password)
# RabbitMQ:         http://localhost:15672 (guest/guest)
# MinIO:            http://localhost:9001 (admin/password123)

# 4. Your app is ready to connect!
# Use variables from .env.example
```

See [QUICKSTART.md](QUICKSTART.md) for more details.

## Architecture at a Glance

```
┌────────────────────────────────┐
│   Application Services         │
│ (NextJS, Go, FFmpeg, React)    │
└────────────┬───────────────────┘
             │
    ┌────────▼────────┐
    │   Local Network │
    └────────┬────────┘
             │
┌────────────▼──────────────────────────┐
│    Docker Compose Network             │
│  (vod-network)                        │
├──────────────────────────────────────┤
│                                       │
│  ┌──────────────────────────────┐   │
│  │   Data & Persistence Layer   │   │
│  ├──────────────────────────────┤   │
│  │ • MongoDB (port 27017)       │   │
│  │ • Redis (port 6379)          │   │
│  │ • MinIO (port 9000)          │   │
│  └──────────────────────────────┘   │
│                                       │
│  ┌──────────────────────────────┐   │
│  │   Messaging & Coordination   │   │
│  ├──────────────────────────────┤   │
│  │ • RabbitMQ (port 5672)       │   │
│  │ • Mongo Express (port 8081)  │   │
│  │ • MinIO Console (port 9001)  │   │
│  └──────────────────────────────┘   │
│                                       │
└──────────────────────────────────────┘
```

## Service Dependencies

```
┌──────────────────────────┐
│ streaming-platform-upload│ → MinIO
└──────────────────────────┘

┌──────────────────────────┐
│ streaming-ingest         │ → MongoDB, RabbitMQ, MinIO
└──────────────────────────┘

┌──────────────────────────┐
│ streaming-transcode      │ → RabbitMQ, MongoDB, MinIO
└──────────────────────────┘

┌──────────────────────────┐
│ streaming-distribution   │ → MongoDB, Redis, MinIO
└──────────────────────────┘

┌──────────────────────────┐
│ streaming-telemetry      │ → RabbitMQ, MongoDB
└──────────────────────────┘
```

## Common Tasks

### I want to...

#### Start working
1. Run `cd infra && docker compose up -d`
2. Run `make ps` to verify
3. Follow [SERVICES_INTEGRATION.md](SERVICES_INTEGRATION.md) for your service
4. Set environment variables from `.env.example`

#### Understand the system
1. Read [INFRASTRUCTURE.md](INFRASTRUCTURE.md) for architecture
2. Check [SERVICES_INTEGRATION.md](SERVICES_INTEGRATION.md) for service connections
3. View data flow diagrams in both documents

#### Debug a problem
1. Run `make test-all` to check infrastructure health
2. Check [README.md](README.md) troubleshooting section
3. Use `make logs` to view service logs
4. Access web UIs to inspect data (Mongo Express, RabbitMQ, MinIO)

#### Reset everything
1. Run `make clean` (warning: deletes all data)
2. Run `make up` to restart

#### Find a specific command
1. Run `make help` to see all Makefile commands
2. Check [README.md](README.md) for detailed instructions

## Key Concepts

### Environment Variables

Two contexts for connection strings:

| Context | Connection | Use When |
|---------|-----------|----------|
| **From Host** | `localhost:27017` | Running services locally on your machine |
| **From Docker** | `mongodb:27017` | Running services inside Docker containers |

Example:
```bash
# Running Node.js locally on your machine
MONGODB_URI=mongodb://admin:password@localhost:27017/streaming

# Running Node.js inside a Docker container
MONGODB_URI=mongodb://admin:password@mongodb:27017/streaming
```

See [SERVICES_INTEGRATION.md](SERVICES_INTEGRATION.md) for each service's variables.

### Data Flow

```
1. Upload Flow
   User Upload → streaming-platform-upload → MinIO
   MinIO webhook → streaming-ingest → RabbitMQ → streaming-transcode

2. Processing Flow
   streaming-transcode → FFmpeg + shaka-packager → MinIO segments
   → Updates MongoDB → Publishes event → streaming-distribution

3. Playback Flow
   Client → streaming-distribution → MongoDB/Redis lookup
   → Returns manifest URL → Client plays from MinIO/CDN
```

See [INFRASTRUCTURE.md](INFRASTRUCTURE.md) for detailed diagrams.

### Health Checks

All services have healthchecks. View status:
```bash
make ps
make test-all
docker compose logs
```

## Files Reference

### Production Files (checked in)
- `docker-compose.yml` — Main configuration (checked in, used by CI/CD)
- `SERVICES_INTEGRATION.md` — Integration guide (reference docs)
- `INFRASTRUCTURE.md` — Architecture docs (reference)
- `Makefile` — Command shortcuts (checked in)

### Local Files (not checked in, generate from template)
- `.env` — Generated from `.env.example`, contains local secrets

## Important Ports

| Service | Port | Purpose | Access |
|---------|------|---------|--------|
| MongoDB | 27017 | Database | `mongosh` CLI or Mongo Express |
| RabbitMQ API | 5672 | Message queue | AMQP protocol |
| RabbitMQ UI | 15672 | Management | http://localhost:15672 |
| Redis | 6379 | Cache | `redis-cli` or Redis UI |
| MinIO API | 9000 | Object storage | S3-compatible API |
| MinIO UI | 9001 | Management | http://localhost:9001 |
| Mongo Express | 8081 | Database UI | http://localhost:8081 |

## Credentials (Development Only)

⚠️ **These are for LOCAL DEVELOPMENT ONLY** — Use real secrets in production.

| Service | Username | Password |
|---------|----------|----------|
| MongoDB | admin | password |
| RabbitMQ | guest | guest |
| MinIO | admin | password123 |
| Mongo Express | admin | password |

## Testing Your Setup

After running `docker compose up -d`:

```bash
# Quick test
make test-all

# Detailed test
make test-mongo
make test-rabbitmq
make test-redis
make test-minio

# Manual testing
curl http://localhost:8081         # Mongo Express
curl http://localhost:15672        # RabbitMQ UI
curl http://localhost:9001         # MinIO UI
```

## Troubleshooting Quick Links

- **Services won't start**: See [README.md#troubleshooting](README.md#troubleshooting)
- **Connection refused**: Check [QUICKSTART.md#troubleshooting](QUICKSTART.md#troubleshooting)
- **Service integration issues**: See [SERVICES_INTEGRATION.md#debugging-checklist](SERVICES_INTEGRATION.md#debugging-checklist)
- **Architecture questions**: Read [INFRASTRUCTURE.md](INFRASTRUCTURE.md)

## Next Steps

1. **First time?** → [QUICKSTART.md](QUICKSTART.md)
2. **Setting up a service?** → [SERVICES_INTEGRATION.md](SERVICES_INTEGRATION.md)
3. **Deep dive?** → [INFRASTRUCTURE.md](INFRASTRUCTURE.md)
4. **Need help?** → `make help` or check [README.md](README.md)

---

**Last Updated**: April 27, 2026  
**Docker Compose Version**: 3.8  
**Designed for**: Local development and testing  
**For production**: Refer to INFRASTRUCTURE.md "Scaling Considerations" and "Production Considerations"
