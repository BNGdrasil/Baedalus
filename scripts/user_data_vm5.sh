#!/bin/bash
# VM5: Backup & Long-term Storage
# OCPU: 2, RAM: 12GB

set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== VM5 Initialization Started ==="
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
echo "Setting up backup and storage..."
mkdir -p /opt/bnbong/{backups,prometheus-storage,grafana-storage}
cd /opt/bnbong

# Create docker-compose.yml for VM5
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # Backup service (pulls data from VM3 primary database)
  # Note: Cross-region backup requires VCN peering or public access
  backup-service:
    image: postgres:15-alpine
    container_name: vm5-backup-service
    environment:
      - POSTGRES_USER=$${POSTGRES_USER}
      - POSTGRES_PASSWORD=$${POSTGRES_PASSWORD}
      - PRIMARY_HOST=${vm3_private_ip}
      - BACKUP_DIR=/backups
    volumes:
      - ./backups:/backups
    command: |
      sh -c 'echo "Backup service ready. Note: Cross-region backup requires VCN peering.";
      while true; do
        sleep 21600;
        echo "Starting backup at $$(date)";
        if nc -z ${vm3_private_ip} 5432 2>/dev/null; then
          PGPASSWORD=$${POSTGRES_PASSWORD} pg_dump -h ${vm3_private_ip} -U $${POSTGRES_USER} -d bnbong | gzip > /backups/bnbong_replica_$$(date +%Y%m%d_%H%M%S).sql.gz;
          PGPASSWORD=$${POSTGRES_PASSWORD} pg_dump -h ${vm3_private_ip} -U $${POSTGRES_USER} -d auth | gzip > /backups/auth_replica_$$(date +%Y%m%d_%H%M%S).sql.gz;
          PGPASSWORD=$${POSTGRES_PASSWORD} pg_dump -h ${vm3_private_ip} -U $${POSTGRES_USER} -d wegis | gzip > /backups/wegis_replica_$$(date +%Y%m%d_%H%M%S).sql.gz;
          find /backups -name "*_replica_*.sql.gz" -mtime +14 -delete;
          echo "Backup completed at $$(date)";
        else
          echo "Cannot reach database at ${vm3_private_ip}:5432 - VCN peering may be required";
        fi;
      done'
    restart: unless-stopped
    networks:
      - backup-network

  # Long-term Prometheus storage (optional)
  prometheus-longterm:
    image: prom/prometheus:latest
    container_name: vm5-prometheus-longterm
    ports:
      - "9090:9090"
    volumes:
      - prometheus_longterm_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=90d'
      - '--web.enable-lifecycle'
    restart: unless-stopped
    networks:
      - backup-network

  # Monitoring agent
  node-exporter:
    image: prom/node-exporter:latest
    container_name: vm5-node-exporter
    ports:
      - "9100:9100"
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    restart: unless-stopped
    networks:
      - backup-network

volumes:
  prometheus_longterm_data:

networks:
  backup-network:
    driver: bridge
COMPOSE_EOF

# Create environment file
cat > .env << ENV_EOF
POSTGRES_USER=${postgres_user}
POSTGRES_PASSWORD=${postgres_password}
ENV_EOF

# Create systemd service
cat > /etc/systemd/system/bnbong-vm5.service << 'SYSTEMD_EOF'
[Unit]
Description=BNGdrasil VM5 Backup and Storage Services
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
systemctl enable bnbong-vm5.service
systemctl start bnbong-vm5.service

echo "=== VM5 Initialization Completed ==="
echo "Services: Backup Service, Prometheus Long-term Storage, Node Exporter"
echo "Backup: Every 6 hours, 14-day retention"
echo "Prometheus: 90-day retention"
echo "Note: Cross-region backup requires VCN peering (VM3: ${vm3_private_ip})"
date
