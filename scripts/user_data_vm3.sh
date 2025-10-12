#!/bin/bash
# VM3: Database Layer (PostgreSQL + Redis + MongoDB)
# OCPU: 1, RAM: 6GB

set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== VM3 Initialization Started ==="
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
mkdir -p /opt/bnbong/postgres/{data,backups}
cd /opt/bnbong

# Create PostgreSQL initialization script
cat > postgres/init.sql << 'SQL_EOF'
-- Create databases
CREATE DATABASE bnbong;
CREATE DATABASE auth;
CREATE DATABASE wegis;

-- Create extensions
\c bnbong;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

\c auth;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

\c wegis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
SQL_EOF

# Create docker-compose.yml for VM3
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # PostgreSQL Database
  postgres:
    image: postgres:15-alpine
    container_name: vm3-postgres
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_USER=$${POSTGRES_USER}
      - POSTGRES_PASSWORD=$${POSTGRES_PASSWORD}
      - POSTGRES_DB=bnbong
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./postgres/init.sql:/docker-entrypoint-initdb.d/init.sql:ro
      - ./postgres/backups:/backups
    command:
      - "postgres"
      - "-c"
      - "max_connections=100"
      - "-c"
      - "shared_buffers=512MB"
      - "-c"
      - "effective_cache_size=1536MB"
      - "-c"
      - "maintenance_work_mem=128MB"
      - "-c"
      - "checkpoint_completion_target=0.9"
      - "-c"
      - "wal_buffers=16MB"
      - "-c"
      - "default_statistics_target=100"
      - "-c"
      - "random_page_cost=1.1"
      - "-c"
      - "effective_io_concurrency=200"
      - "-c"
      - "work_mem=2621kB"
      - "-c"
      - "min_wal_size=1GB"
      - "-c"
      - "max_wal_size=4GB"
    restart: unless-stopped
    networks:
      - db-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Redis for caching
  redis:
    image: redis:7-alpine
    container_name: vm3-redis
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes --maxmemory 2gb --maxmemory-policy allkeys-lru
    restart: unless-stopped
    networks:
      - db-network

  # MongoDB for Wegis data
  mongodb:
    image: mongo:7
    container_name: vm3-mongodb
    ports:
      - "27017:27017"
    environment:
      - MONGO_INITDB_ROOT_USERNAME=wegis
      - MONGO_INITDB_ROOT_PASSWORD=wegis_secure_password
      - MONGO_INITDB_DATABASE=wegis
    volumes:
      - mongodb_data:/data/db
      - mongodb_config:/data/configdb
    restart: unless-stopped
    networks:
      - db-network
    command: mongod --wiredTigerCacheSizeGB 2

  # PostgreSQL backup container (runs daily)
  postgres-backup:
    image: postgres:15-alpine
    container_name: vm3-backup
    environment:
      - POSTGRES_USER=$${POSTGRES_USER}
      - POSTGRES_PASSWORD=$${POSTGRES_PASSWORD}
      - POSTGRES_HOST=postgres
      - BACKUP_DIR=/backups
    volumes:
      - ./postgres/backups:/backups
    command: |
      sh -c 'while true; do
        sleep 86400;
        pg_dump -h postgres -U $${POSTGRES_USER} -d bnbong | gzip > /backups/bnbong_$$(date +%Y%m%d_%H%M%S).sql.gz;
        pg_dump -h postgres -U $${POSTGRES_USER} -d auth | gzip > /backups/auth_$$(date +%Y%m%d_%H%M%S).sql.gz;
        pg_dump -h postgres -U $${POSTGRES_USER} -d wegis | gzip > /backups/wegis_$$(date +%Y%m%d_%H%M%S).sql.gz;
        find /backups -name "*.sql.gz" -mtime +7 -delete;
      done'
    depends_on:
      - postgres
    restart: unless-stopped
    networks:
      - db-network

volumes:
  postgres_data:
  redis_data:
  mongodb_data:
  mongodb_config:

networks:
  db-network:
    driver: bridge
COMPOSE_EOF

# Create environment file for Docker Compose
cat > .env << ENV_EOF
POSTGRES_USER=${postgres_user}
POSTGRES_PASSWORD=${postgres_password}
ENV_EOF

# Create systemd service
cat > /etc/systemd/system/bnbong-vm3.service << 'SYSTEMD_EOF'
[Unit]
Description=BNGdrasil VM3 Database Services
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

# Enable and start service
systemctl daemon-reload
systemctl enable bnbong-vm3.service
systemctl start bnbong-vm3.service

echo "=== VM3 Initialization Completed ==="
echo "Services: PostgreSQL, Redis, MongoDB, Automated Backups"
echo "Databases: bnbong, auth, wegis"
echo "Backup: Daily at midnight, 7-day retention"
date
