#!/bin/bash
# BNGdrasil Services Deployment Script

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Log functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if Terraform outputs are available
if [ ! -f terraform.tfstate ]; then
    log_error "terraform.tfstate not found. Please run 'terraform apply' first."
    exit 1
fi

# Get VM IPs
VM1_IP=$(terraform output -raw vm1_public_ip 2>/dev/null)
VM2_IP=$(terraform output -raw vm2_public_ip 2>/dev/null)
VM4_PRIVATE_IP=$(terraform output -raw vm4_private_ip 2>/dev/null)

if [ -z "$VM1_IP" ] || [ -z "$VM2_IP" ]; then
    log_error "Could not retrieve VM IP addresses from Terraform outputs"
    exit 1
fi

log_info "VM1 IP: $VM1_IP"
log_info "VM2 IP: $VM2_IP"
log_info "VM4 Private IP: $VM4_PRIVATE_IP"

# Project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

log_info "Project root: $PROJECT_ROOT"

# ========================================
# Deploy to VM2 (Backend Services)
# ========================================

log_info "Deploying backend services to VM2..."

# Create remote directory
ssh ubuntu@$VM2_IP "sudo mkdir -p /opt/bnbong/{gateway,auth-server} && sudo chown -R ubuntu:ubuntu /opt/bnbong"

# Copy Gateway source code
log_info "Copying Gateway (Bifrost) source code..."
rsync -avz --exclude='.git' --exclude='node_modules' --exclude='__pycache__' --exclude='.venv' \
    --exclude='*.pyc' --exclude='.DS_Store' --exclude='htmlcov' --exclude='.pytest_cache' \
    "$PROJECT_ROOT/gateway/" ubuntu@$VM2_IP:/opt/bnbong/gateway/

# Copy Auth Server source code
log_info "Copying Auth Server (Bidar) source code..."
rsync -avz --exclude='.git' --exclude='node_modules' --exclude='__pycache__' --exclude='.venv' \
    --exclude='*.pyc' --exclude='.DS_Store' --exclude='htmlcov' --exclude='.pytest_cache' \
    "$PROJECT_ROOT/auth-server/" ubuntu@$VM2_IP:/opt/bnbong/auth-server/

# Create .env file on VM2
log_info "Creating .env file on VM2..."
ssh ubuntu@$VM2_IP "cat > /opt/bnbong/.env << 'ENV_EOF'
# Environment
ENVIRONMENT=production
DEBUG=false
LOG_LEVEL=INFO

# Domain
DOMAIN_NAME=bnbong.com

# Database (VM4 in Osaka)
POSTGRES_USER=bnbong
POSTGRES_PASSWORD=change-this-password
DATABASE_URL=postgresql://bnbong:change-this-password@${VM4_PRIVATE_IP}:5432/bnbong

# Redis (local)
REDIS_URL=redis://redis:6379/0

# JWT
JWT_SECRET_KEY=change-this-to-secure-key-min-32-chars
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30
REFRESH_TOKEN_EXPIRE_DAYS=7

# Auth Server URL
AUTH_SERVER_URL=http://auth-server:8001

# Rate Limiting
RATE_LIMIT_PER_MINUTE=60
ENV_EOF
"

# Create docker-compose.yml on VM2
log_info "Creating docker-compose.yml on VM2..."
ssh ubuntu@$VM2_IP "cat > /opt/bnbong/docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # Redis for caching and sessions
  redis:
    image: redis:7-alpine
    container_name: vm2-redis
    ports:
      - \"6379:6379\"
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes --maxmemory 2gb --maxmemory-policy allkeys-lru
    restart: unless-stopped
    networks:
      - api-network

  # Auth Server (Bidar)
  auth-server:
    build:
      context: ./auth-server
      dockerfile: Dockerfile
    container_name: vm2-auth
    ports:
      - \"8001:8001\"
    env_file:
      - .env
    depends_on:
      - redis
    restart: unless-stopped
    networks:
      - api-network
    healthcheck:
      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:8001/health\"]
      interval: 30s
      timeout: 10s
      retries: 3

  # API Gateway (Bifrost)
  gateway:
    build:
      context: ./gateway
      dockerfile: Dockerfile
    container_name: vm2-gateway
    ports:
      - \"8000:8000\"
    env_file:
      - .env
    depends_on:
      - auth-server
      - redis
    restart: unless-stopped
    networks:
      - api-network
    healthcheck:
      test: [\"CMD\", \"curl\", \"-f\", \"http://localhost:8000/health\"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  redis_data:

networks:
  api-network:
    driver: bridge
COMPOSE_EOF
"

# Build and start services on VM2
log_info "Building and starting services on VM2..."
ssh ubuntu@$VM2_IP "cd /opt/bnbong && docker-compose build && docker-compose up -d"

log_info "Waiting for services to start..."
sleep 20

# Check service health
log_info "Checking service health on VM2..."
ssh ubuntu@$VM2_IP "cd /opt/bnbong && docker-compose ps"

# ========================================
# Deploy to VM1 (Frontend)
# ========================================

log_info "Deploying frontend to VM1..."

# Create remote directory
ssh ubuntu@$VM1_IP "sudo mkdir -p /opt/bnbong/client/dist && sudo chown -R ubuntu:ubuntu /opt/bnbong"

# Build client locally if needed
if [ -d "$PROJECT_ROOT/client/dist" ]; then
    log_info "Client already built. Copying dist files..."
else
    log_info "Building client..."
    cd "$PROJECT_ROOT/client"
    npm install
    npm run build
    cd -
fi

# Copy client dist
log_info "Copying client dist to VM1..."
rsync -avz "$PROJECT_ROOT/client/dist/" ubuntu@$VM1_IP:/opt/bnbong/client/dist/

# Copy nginx configuration
log_info "Updating nginx configuration on VM1..."
ssh ubuntu@$VM1_IP "sudo tee /etc/nginx/sites-available/default > /dev/null << 'NGINX_EOF'
server {
    listen 80;
    server_name bnbong.com www.bnbong.com;

    root /opt/bnbong/client/dist;
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    # API proxy
    location /api/ {
        proxy_pass http://${VM2_IP}:8000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
NGINX_EOF
"

# Reload nginx
log_info "Reloading nginx on VM1..."
ssh ubuntu@$VM1_IP "sudo nginx -t && sudo systemctl reload nginx"

log_info "================================"
log_info "Deployment completed!"
log_info "================================"
log_info ""
log_info "VM1 (Frontend): http://$VM1_IP"
log_info "VM2 (Gateway): http://$VM2_IP:8000"
log_info "VM2 (Auth): http://$VM2_IP:8001"
log_info ""
log_info "Next steps:"
log_info "1. Configure DNS to point to $VM1_IP"
log_info "2. Setup SSL certificates"
log_info "3. Update .env file with secure passwords"
log_info ""
log_info "Check service status:"
log_info "  ssh ubuntu@$VM2_IP 'cd /opt/bnbong && docker-compose logs -f'"

