#!/bin/bash
# Create a new MSA service template
# Usage: ./create-service.sh <service-name> <port>

set -e

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <service-name> <port>"
    echo "Example: $0 user-service 8002"
    exit 1
fi

SERVICE_NAME=$1
SERVICE_PORT=$2
REDIS_DB=$((SERVICE_PORT - 8000))  # Auto-calculate Redis DB number

echo "Creating MSA service: $SERVICE_NAME on port $SERVICE_PORT"

# Create docker-compose file
cat > "docker-compose.${SERVICE_NAME}.yml" << EOF
version: '3.8'

services:
  ${SERVICE_NAME}:
    build:
      context: ./${SERVICE_NAME}
      dockerfile: Dockerfile
    container_name: vm2-${SERVICE_NAME}
    environment:
      - ENVIRONMENT=\${ENVIRONMENT}
      - DEBUG=\${DEBUG}
      - LOG_LEVEL=\${LOG_LEVEL}
      - HOST=0.0.0.0
      - PORT=${SERVICE_PORT}
      - DATABASE_URL=\${DATABASE_URL}
      - REDIS_URL=redis://redis:6379/${REDIS_DB}
      - AUTH_SERVER_URL=http://auth-server:8001
    restart: unless-stopped
    networks:
      - msa-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${SERVICE_PORT}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

networks:
  msa-network:
    external: true
EOF

# Update services.json for Gateway
SERVICE_JSON=$(cat << EOF
  "${SERVICE_NAME}": {
    "url": "http://${SERVICE_NAME}:${SERVICE_PORT}",
    "health_check": "/health",
    "timeout": 30,
    "rate_limit": 100,
    "retry": {
      "max_attempts": 3,
      "backoff_factor": 2
    }
  }
EOF
)

echo ""
echo "✅ Created: docker-compose.${SERVICE_NAME}.yml"
echo ""
echo "Next steps:"
echo "1. Create service directory: mkdir -p ${SERVICE_NAME}"
echo "2. Add Dockerfile and code to ${SERVICE_NAME}/"
echo "3. Add this to bifrost/config/services.json:"
echo ""
echo "$SERVICE_JSON"
echo ""
echo "4. Deploy: make add-service SERVICE=${SERVICE_NAME}"

