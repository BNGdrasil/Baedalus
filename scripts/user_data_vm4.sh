#!/bin/bash
# VM4: Monitoring & Observability (Prometheus + Grafana + Loki)
# OCPU: 1, RAM: 6GB

set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== VM4 Initialization Started ==="
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
echo "Setting up monitoring stack..."
mkdir -p /opt/bnbong/{prometheus,grafana,loki,alertmanager}
cd /opt/bnbong

# Create Prometheus configuration
cat > prometheus/prometheus.yml << 'PROM_EOF'
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: 'bngdrasil'
    region: 'osaka'

# Alertmanager configuration
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

# Scrape configurations
scrape_configs:
  # Prometheus itself
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Note: Cross-region monitoring requires VCN peering
  # VM1-3 are in Chuncheon region (${vm1_private_ip}, ${vm2_private_ip}, ${vm3_private_ip})
  # Direct access may not work without VCN Remote Peering Connection (RPC)
  
  # VM1: Frontend
  - job_name: 'vm1-frontend'
    static_configs:
      - targets: ['${vm1_private_ip}:9100']
        labels:
          instance: 'vm1-frontend'
          region: 'chuncheon'

  # VM2: Core APIs
  - job_name: 'vm2-core-apis'
    static_configs:
      - targets: ['${vm2_private_ip}:9100']
        labels:
          instance: 'vm2-core-apis'
          region: 'chuncheon'
      - targets: ['${vm2_private_ip}:8000']
        labels:
          service: 'gateway'
      - targets: ['${vm2_private_ip}:8001']
        labels:
          service: 'auth-server'

  # VM3: Database
  - job_name: 'vm3-database'
    static_configs:
      - targets: ['${vm3_private_ip}:9100']
        labels:
          instance: 'vm3-database'
          region: 'chuncheon'
PROM_EOF

# Create Loki configuration
cat > loki/loki-config.yml << 'LOKI_EOF'
auth_enabled: false

server:
  http_listen_port: 3100

ingester:
  lifecycler:
    address: 127.0.0.1
    ring:
      kvstore:
        store: inmemory
      replication_factor: 1
  chunk_idle_period: 5m
  chunk_retain_period: 30s

schema_config:
  configs:
    - from: 2024-01-01
      store: boltdb
      object_store: filesystem
      schema: v11
      index:
        prefix: index_
        period: 24h

storage_config:
  boltdb:
    directory: /loki/index
  filesystem:
    directory: /loki/chunks

limits_config:
  enforce_metric_name: false
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  retention_period: 168h

compactor:
  working_directory: /loki/compactor
  shared_store: filesystem
  retention_enabled: true
  retention_delete_delay: 2h
LOKI_EOF

# Create Alertmanager configuration
cat > alertmanager/alertmanager.yml << 'ALERT_EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'cluster', 'service']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 12h
  receiver: 'default'

receivers:
  - name: 'default'
    # Configure your notification method here
    # webhook_configs:
    #   - url: 'http://your-webhook-url'
ALERT_EOF

# Create docker-compose.yml for VM4
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  # Prometheus
  prometheus:
    image: prom/prometheus:latest
    container_name: vm4-prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    restart: unless-stopped
    networks:
      - monitoring-network

  # Grafana
  grafana:
    image: grafana/grafana:latest
    container_name: vm4-grafana
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=http://monitoring.internal
      - GF_INSTALL_PLUGINS=grafana-clock-panel,grafana-simple-json-datasource
    volumes:
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus
      - loki
    restart: unless-stopped
    networks:
      - monitoring-network

  # Loki (Log aggregation)
  loki:
    image: grafana/loki:latest
    container_name: vm4-loki
    ports:
      - "3100:3100"
    volumes:
      - ./loki/loki-config.yml:/etc/loki/local-config.yaml:ro
      - loki_data:/loki
    command: -config.file=/etc/loki/local-config.yaml
    restart: unless-stopped
    networks:
      - monitoring-network

  # Alertmanager
  alertmanager:
    image: prom/alertmanager:latest
    container_name: vm4-alertmanager
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    command:
      - '--config.file=/etc/alertmanager/alertmanager.yml'
      - '--storage.path=/alertmanager'
    restart: unless-stopped
    networks:
      - monitoring-network

volumes:
  prometheus_data:
  grafana_data:
  loki_data:
  alertmanager_data:

networks:
  monitoring-network:
    driver: bridge
COMPOSE_EOF

# Create systemd service
cat > /etc/systemd/system/bnbong-vm4.service << 'SYSTEMD_EOF'
[Unit]
Description=BNGdrasil VM4 Monitoring Stack
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
systemctl enable bnbong-vm4.service
systemctl start bnbong-vm4.service

echo "=== VM4 Initialization Completed ==="
echo "Services: Prometheus, Grafana, Loki, Alertmanager"
echo "Grafana: http://localhost:3000 (admin/admin)"
echo "Prometheus: http://localhost:9090"
echo "Loki: http://localhost:3100"
echo "Note: Cross-region monitoring requires VCN peering setup"
date
