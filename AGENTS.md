# Infrastructure — AI Agent Instructions

## Role

Centralized infrastructure configuration for the VOD platform. Provides shared Docker Compose stack (MongoDB, RabbitMQ, Redis, MinIO), Terraform for AWS provisioning, CI/CD pipeline specs, and an AWS learning path.

## Source of Truth

**All infrastructure documentation lives in `obsidian-vault/infra/`.** Only `README.md` and `AGENTS.md` remain in this directory.

Vault entry: `obsidian-vault/infra/_INDEX.md`

## Key Vault Documents

| Document | Vault Path |
|----------|-----------|
| Infrastructure overview | `obsidian-vault/infra/_INDEX.md` |
| Docker Compose summary | `obsidian-vault/infra/docker-compose.md` |
| Full infra README | `obsidian-vault/infra/README.md` |
| Quick start | `obsidian-vault/infra/QUICKSTART.md` |
| Services integration | `obsidian-vault/infra/SERVICES_INTEGRATION.md` |
| Terraform (AWS IaC) | `obsidian-vault/infra/terraform.md` |
| AWS learning path | `obsidian-vault/infra/learning-path/` |
| Pipeline specs | `obsidian-vault/infra/pipelines/` |

## Local Stack

Start all infrastructure:

```bash
docker compose up -d
make ps
```

Components: MongoDB :27017, RabbitMQ :5672/:15672, Redis :6379, MinIO :9000/:9001
