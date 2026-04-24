#!/bin/bash
# VM1: Frontend & Proxy (Nginx + Client)
# OCPU: 1, RAM: 6GB

set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== VM1 Initialization Started ==="
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
mkdir -p /opt/bnbong/{nginx/conf.d,nginx/ssl,client}
cd /opt/bnbong

# Create Nginx configuration
# Note: VM2 private IP for API proxying
VM2_IP="10.0.1.60"

cat > nginx/nginx.conf << NGINX_EOF
events {
    worker_connections 2048;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    # Logging
    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';
    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript application/json application/javascript application/xml+rss;

    # Rate limiting
    limit_req_zone \$binary_remote_addr zone=api:10m rate=10r/s;
    limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;

    # Upstream servers (VM2 - Core APIs)
    upstream gateway {
        server $VM2_IP:8000;
    }

    upstream auth_server {
        server $VM2_IP:8001;
    }

    # Security headers
    add_header X-Frame-Options "DENY" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # Main site (Portfolio)
    server {
        listen 80;
        server_name ${domain_name} www.${domain_name};
        
        root /usr/share/nginx/html/client;
        index index.html;
        
        # Static files
        location / {
            try_files \$uri \$uri/ /index.html;
        }
        
        # Cache static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # API Gateway
    server {
        listen 80;
        server_name api.${domain_name};
        
        # API Gateway with rate limiting
        location / {
            limit_req zone=api burst=20 nodelay;
            proxy_pass http://gateway;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            
            # Cloudflare headers (if behind Cloudflare)
            proxy_set_header CF-Connecting-IP \$http_cf_connecting_ip;
            proxy_set_header CF-Ray \$http_cf_ray;
            
            # Timeouts
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }
        
        # Auth endpoints (direct access if needed)
        location /auth {
            limit_req zone=login burst=5 nodelay;
            proxy_pass http://auth_server;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            
            # Timeouts
            proxy_connect_timeout 60s;
            proxy_send_timeout 60s;
            proxy_read_timeout 60s;
        }
    }

    # Default server (reject unknown hosts)
    server {
        listen 80 default_server;
        server_name _;
        return 444;
    }
}
NGINX_EOF

# Create docker-compose.yml for VM1
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

services:
  nginx:
    image: nginx:alpine
    container_name: vm1-nginx
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./client/dist:/usr/share/nginx/html/client:ro
      - ./nginx/ssl:/etc/nginx/ssl:ro
    restart: unless-stopped
    networks:
      - frontend-network

networks:
  frontend-network:
    driver: bridge
COMPOSE_EOF

# Create placeholder directories
mkdir -p client/dist
echo "<h1>BNGdrasil - Coming Soon</h1>" > client/dist/index.html

# Create systemd service
cat > /etc/systemd/system/bnbong-vm1.service << 'SYSTEMD_EOF'
[Unit]
Description=BNGdrasil VM1 Frontend Services
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/bnbong
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# Enable and start service
systemctl daemon-reload
systemctl enable bnbong-vm1.service
systemctl start bnbong-vm1.service

echo "=== VM1 Initialization Completed ==="
echo "Services: Nginx (Frontend Proxy)"
echo "Status: $(systemctl is-active bnbong-vm1.service)"
date
