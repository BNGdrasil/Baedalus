# VM2 Services Management Makefile
#
# 운영 VM2의 core compose 파일 이름은 docker-compose.yml이다. 이전 판이 참조하던
# docker-compose.core.yml은 이 저장소에도 운영 서버에도 존재하지 않았다.

COMPOSE_FILE ?= docker-compose.yml
COMPOSE      ?= docker compose

.PHONY: help start-core stop-core restart-core config \
        add-service remove-service restart-service \
        status logs clean

# Default target
help:
	@echo "VM2 Services Management"
	@echo ""
	@echo "Core Services:"
	@echo "  make start-core          - Start core services (Gateway, Auth, Redis)"
	@echo "  make stop-core           - Stop core services"
	@echo "  make restart-core        - Restart core services"
	@echo "  make config              - Validate the core compose file"
	@echo ""
	@echo "Additional Services:"
	@echo "  make add-service SERVICE=wegis-server     - Start an additional service"
	@echo "  make remove-service SERVICE=wegis-server  - Stop an additional service"
	@echo "  make restart-service SERVICE=wegis-server - Restart a specific service"
	@echo ""
	@echo "Monitoring:"
	@echo "  make status              - Show all running containers"
	@echo "  make logs SERVICE=wegis-server  - View logs for a service"
	@echo "  make clean               - Remove stopped containers and dangling images"

# Core services
start-core:
	@echo "Starting core services..."
	$(COMPOSE) -f $(COMPOSE_FILE) up -d

stop-core:
	@echo "Stopping core services..."
	$(COMPOSE) -f $(COMPOSE_FILE) down

restart-core:
	@echo "Restarting core services..."
	$(COMPOSE) -f $(COMPOSE_FILE) restart

config:
	@echo "Validating $(COMPOSE_FILE)..."
	$(COMPOSE) -f $(COMPOSE_FILE) config --quiet
	@echo "OK"

# Additional service management
add-service:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Error: SERVICE parameter required. Usage: make add-service SERVICE=wegis-server"; \
		exit 1; \
	fi
	@if [ ! -f "docker-compose.$(SERVICE).yml" ]; then \
		echo "Error: docker-compose.$(SERVICE).yml not found"; \
		exit 1; \
	fi
	@echo "Starting $(SERVICE)..."
	$(COMPOSE) -f docker-compose.$(SERVICE).yml up -d --build

remove-service:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Error: SERVICE parameter required. Usage: make remove-service SERVICE=wegis-server"; \
		exit 1; \
	fi
	@echo "Removing $(SERVICE)..."
	$(COMPOSE) -f docker-compose.$(SERVICE).yml down

restart-service:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Error: SERVICE parameter required. Usage: make restart-service SERVICE=wegis-server"; \
		exit 1; \
	fi
	@echo "Restarting $(SERVICE)..."
	$(COMPOSE) -f docker-compose.$(SERVICE).yml restart

# Monitoring
status:
	@echo "All running containers:"
	@docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

logs:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Showing logs for core services..."; \
		$(COMPOSE) -f $(COMPOSE_FILE) logs -f; \
	else \
		echo "Showing logs for $(SERVICE)..."; \
		$(COMPOSE) -f docker-compose.$(SERVICE).yml logs -f; \
	fi

# Cleanup
# DATA-03: `docker volume prune`을 일반 정리에서 제외했다. 이 명령은 중지된
# 컨테이너의 volume까지 지우므로 Redis AOF, Grafana DB, Prometheus 저장 블록을
# 잃을 수 있다. volume을 지워야 한다면 대상을 직접 지정하고 백업을 먼저 확인한다.
clean:
	@echo "Removing stopped containers and dangling images..."
	docker container prune -f
	docker image prune -f
	@echo "Note: volumes are intentionally left untouched. See DATA-03."

# Update gateway config
update-gateway-config:
	@echo "Reloading Gateway configuration..."
	$(COMPOSE) -f $(COMPOSE_FILE) restart gateway
