.PHONY: help up down logs status restart clean test-mongo test-rabbitmq test-redis test-minio ps build

help:
	@echo "VOD Platform Infrastructure - Common Commands"
	@echo ""
	@echo "Setup & Management:"
	@echo "  make up              - Start all infrastructure services"
	@echo "  make down            - Stop all infrastructure services"
	@echo "  make restart         - Restart all services"
	@echo "  make clean           - Stop and remove all volumes (reset everything)"
	@echo "  make ps              - Show status of all services"
	@echo "  make logs            - Show logs from all services (follow mode)"
	@echo "  make build           - Build/rebuild all images"
	@echo ""
	@echo "Testing & Verification:"
	@echo "  make test-mongo      - Test MongoDB connection"
	@echo "  make test-rabbitmq   - Test RabbitMQ connection"
	@echo "  make test-redis      - Test Redis connection"
	@echo "  make test-minio      - Test MinIO connection"
	@echo "  make test-all        - Test all services"
	@echo ""
	@echo "Utilities:"
	@echo "  make shell-mongo     - Open MongoDB shell"
	@echo "  make shell-redis     - Open Redis CLI"
	@echo "  make reset-buckets   - Recreate MinIO buckets"
	@echo "  make env-setup       - Copy .env.example to .env"
	@echo ""

# Core commands
up:
	@echo "Starting infrastructure..."
	docker compose up -d
	@echo "✓ Infrastructure started"
	@echo ""
	@echo "Service URLs:"
	@echo "  MongoDB:     mongodb://admin:password@localhost:27017"
	@echo "  RabbitMQ:    http://localhost:15672 (guest/guest)"
	@echo "  Redis:       redis://localhost:6379"
	@echo "  MinIO:       http://localhost:9001 (admin/password123)"
	@echo "  Mongo UI:    http://localhost:8081 (admin/password)"

down:
	@echo "Stopping infrastructure..."
	docker compose down
	@echo "✓ Infrastructure stopped"

restart:
	@echo "Restarting infrastructure..."
	docker compose restart
	@echo "✓ Infrastructure restarted"

clean:
	@echo "WARNING: This will delete all data volumes!"
	@echo "Press Ctrl+C to cancel, or wait 5 seconds..."
	@sleep 5
	docker compose down -v
	@echo "✓ All data removed"

ps:
	@docker compose ps

logs:
	docker compose logs -f

build:
	docker compose build

# Testing commands
test-mongo:
	@echo "Testing MongoDB connection..."
	@docker exec mongodb mongosh --version > /dev/null 2>&1 && \
		docker exec mongodb mongosh "mongodb://admin:password@localhost:27017/?authSource=admin" \
			--eval "db.runCommand('ping')" 2>&1 | grep -q "1" && \
		echo "✓ MongoDB is healthy" || echo "✗ MongoDB connection failed"

test-rabbitmq:
	@echo "Testing RabbitMQ connection..."
	@docker exec rabbitmq rabbitmq-diagnostics -q ping > /dev/null 2>&1 && \
		echo "✓ RabbitMQ is healthy" || echo "✗ RabbitMQ connection failed"

test-redis:
	@echo "Testing Redis connection..."
	@docker exec redis redis-cli ping > /dev/null 2>&1 && \
		echo "✓ Redis is healthy" || echo "✗ Redis connection failed"

test-minio:
	@echo "Testing MinIO connection..."
	@docker exec minio curl -s http://localhost:9000/minio/health/live > /dev/null 2>&1 && \
		echo "✓ MinIO is healthy" || echo "✗ MinIO connection failed"

test-all: test-mongo test-rabbitmq test-redis test-minio
	@echo ""
	@echo "✓ All services are healthy!"

# Shell access
shell-mongo:
	@docker exec -it mongodb mongosh "mongodb://admin:password@localhost:27017/streaming?authSource=admin"

shell-redis:
	@docker exec -it redis redis-cli

shell-rabbitmq:
	@echo "RabbitMQ Management UI: http://localhost:15672 (guest/guest)"

shell-mongo-express:
	@echo "Mongo Express: http://localhost:8081 (admin/password)"

# MinIO utilities
reset-buckets:
	@echo "Resetting MinIO buckets..."
	@docker exec minio mc alias set local http://localhost:9000 admin password123 > /dev/null 2>&1
	@docker exec minio mc rm -r --force local/videos > /dev/null 2>&1 || true
	@docker exec minio mc mb local/videos
	@echo "✓ MinIO buckets reset"

# Setup
env-setup:
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "✓ .env file created from .env.example"; \
	else \
		echo "⚠ .env file already exists"; \
	fi

# Status checks
status:
	@echo "Infrastructure Status"
	@echo "====================="
	@docker compose ps
	@echo ""
	@echo "Service Health Checks:"
	@make -s test-all 2>/dev/null || true

# Docker cleanup
docker-clean:
	@echo "Removing unused Docker resources..."
	@docker system prune -f
	@echo "✓ Docker cleanup complete"

# Logs for specific services
logs-mongo:
	docker compose logs -f mongodb

logs-rabbitmq:
	docker compose logs -f rabbitmq

logs-redis:
	docker compose logs -f redis

logs-minio:
	docker compose logs -f minio

# Advanced commands
validate:
	@echo "Validating docker-compose.yml..."
	@docker compose config --quiet && echo "✓ Configuration is valid" || echo "✗ Configuration has errors"

pull:
	@echo "Pulling latest images..."
	docker compose pull

version:
	@echo "Docker Compose Version:"
	@docker compose --version
	@echo ""
	@echo "Docker Version:"
	@docker --version
