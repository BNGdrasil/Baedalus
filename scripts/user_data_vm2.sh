#!/bin/bash
# VM2: Core APIs (Gateway + Auth Server + Redis)
# OCPU: 1, RAM: 6GB

set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== VM2 Initialization Started ==="
date

# Update system
echo "Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install Docker
echo "Installing Docker..."
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=arm64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# Install Docker Compose
echo "Installing Docker Compose..."
curl -L "https://github.com/docker/compose/releases/download/v2.24.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose
ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

# Enable and start Docker
systemctl enable docker
systemctl start docker

# Create application directory
echo "Setting up application directory..."
mkdir -p /opt/bnbong/{gateway,auth-server}
cd /opt/bnbong

# Create environment file
cat > .env << ENV_EOF
# Environment
ENVIRONMENT=production
DEBUG=false
LOG_LEVEL=INFO

# Domain
DOMAIN_NAME=${domain_name}

# Database (VM3 in Chuncheon)
POSTGRES_USER=${postgres_user}
POSTGRES_PASSWORD=${postgres_password}
DATABASE_URL=postgresql://${postgres_user}:${postgres_password}@${vm3_private_ip}:5432/bnbong

# Redis (local)
REDIS_URL=redis://redis:6379/0

# JWT
JWT_SECRET_KEY=${jwt_secret_key}
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30
REFRESH_TOKEN_EXPIRE_DAYS=7

# Auth Server URL
AUTH_SERVER_URL=http://auth-server:8001

# Rate Limiting
RATE_LIMIT_PER_MINUTE=60
ENV_EOF

# Create docker-compose.yml for VM2
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # Redis for caching and sessions
  redis:
    image: redis:7-alpine
    container_name: vm2-redis
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes --maxmemory 2gb --maxmemory-policy allkeys-lru
    restart: unless-stopped
    networks:
      - api-network

  # Auth Server (Bidar)
  auth-server:
    image: ghcr.io/bngdrasil/bidar:latest
    container_name: vm2-auth
    ports:
      - "8001:8001"
    environment:
      - ENVIRONMENT=$${ENVIRONMENT}
      - DATABASE_URL=$${DATABASE_URL}
      - REDIS_URL=$${REDIS_URL}
      - JWT_SECRET_KEY=$${JWT_SECRET_KEY}
      - JWT_ALGORITHM=$${JWT_ALGORITHM}
      - ACCESS_TOKEN_EXPIRE_MINUTES=$${ACCESS_TOKEN_EXPIRE_MINUTES}
      - REFRESH_TOKEN_EXPIRE_DAYS=$${REFRESH_TOKEN_EXPIRE_DAYS}
    depends_on:
      - redis
    restart: unless-stopped
    networks:
      - api-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8001/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # API Gateway (Bifrost)
  gateway:
    image: ghcr.io/bngdrasil/bifrost:latest
    container_name: vm2-gateway
    ports:
      - "8000:8000"
    environment:
      - ENVIRONMENT=$${ENVIRONMENT}
      - AUTH_SERVER_URL=$${AUTH_SERVER_URL}
      - REDIS_URL=$${REDIS_URL}
      - LOG_LEVEL=$${LOG_LEVEL}
      - RATE_LIMIT_PER_MINUTE=$${RATE_LIMIT_PER_MINUTE}
    depends_on:
      - auth-server
      - redis
    restart: unless-stopped
    networks:
      - api-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  redis_data:

networks:
  api-network:
    driver: bridge
COMPOSE_EOF

# Create systemd service
cat > /etc/systemd/system/bnbong-vm2.service << 'SYSTEMD_EOF'
[Unit]
Description=BNGdrasil VM2 Core API Services
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/bnbong
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# Enable service (will start after images are pulled)
systemctl daemon-reload
systemctl enable bnbong-vm2.service

echo "=== VM2 Initialization Completed ==="
echo "Services: Gateway, Auth Server, Redis"
echo "Note: Service will start after Docker images are pulled"
date

