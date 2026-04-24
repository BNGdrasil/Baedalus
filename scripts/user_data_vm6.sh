#!/bin/bash
# VM6: Sandbox & Development Environment
# OCPU: 1, RAM: 6GB

set -e

# Logging
exec > >(tee /var/log/user-data.log)
exec 2>&1

echo "=== VM6 Initialization Started ==="
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

# Install development tools
echo "Installing development tools..."
apt-get install -y \
    git \
    vim \
    nano \
    htop \
    tmux \
    jq \
    wget \
    unzip \
    build-essential \
    python3 \
    python3-pip \
    nodejs \
    npm

# Install additional utilities
echo "Installing additional utilities..."
apt-get install -y \
    postgresql-client \
    mongodb-clients \
    redis-tools \
    net-tools \
    iputils-ping \
    traceroute \
    dnsutils

# Create sandbox directory
echo "Setting up sandbox environment..."
mkdir -p /opt/sandbox/{projects,data,scripts}
cd /opt/sandbox

# Create a simple README
cat > README.md << 'README_EOF'
# BNGdrasil Sandbox Environment

This VM is designated for development, testing, and experimentation.

## Available Tools
- Docker & Docker Compose
- Git
- Python 3
- Node.js & npm
- PostgreSQL client
- MongoDB client
- Redis client

## Directory Structure
- `/opt/sandbox/projects`: Your project files
- `/opt/sandbox/data`: Test data
- `/opt/sandbox/scripts`: Utility scripts

## Quick Start
```bash
cd /opt/sandbox/projects
# Start your development here
```

## Notes
- This VM is in a private subnet in the Osaka region
- SSH access requires VCN peering or a jump host
- Feel free to install additional tools as needed
README_EOF

# Create docker-compose.yml for quick testing
cat > docker-compose.yml << 'COMPOSE_EOF'
version: '3.8'

# Example services for testing
# Uncomment and modify as needed

services:
  # Example: Nginx for testing
  # nginx:
  #   image: nginx:alpine
  #   container_name: sandbox-nginx
  #   ports:
  #     - "8080:80"
  #   volumes:
  #     - ./projects:/usr/share/nginx/html:ro
  #   restart: unless-stopped

  # Example: PostgreSQL for testing
  # postgres:
  #   image: postgres:15-alpine
  #   container_name: sandbox-postgres
  #   environment:
  #     - POSTGRES_USER=testuser
  #     - POSTGRES_PASSWORD=testpass
  #     - POSTGRES_DB=testdb
  #   ports:
  #     - "5432:5432"
  #   volumes:
  #     - postgres_data:/var/lib/postgresql/data
  #   restart: unless-stopped

  # Example: Redis for testing
  # redis:
  #   image: redis:7-alpine
  #   container_name: sandbox-redis
  #   ports:
  #     - "6379:6379"
  #   restart: unless-stopped

  # Monitoring agent (always active)
  node-exporter:
    image: prom/node-exporter:latest
    container_name: sandbox-node-exporter
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

# volumes:
#   postgres_data:
COMPOSE_EOF

# Create a welcome script
cat > /etc/profile.d/sandbox-welcome.sh << 'WELCOME_EOF'
#!/bin/bash
if [ -n "$PS1" ]; then
    echo "======================================"
    echo "  BNGdrasil Sandbox Environment"
    echo "======================================"
    echo ""
    echo "Workspace: /opt/sandbox"
    echo "README: /opt/sandbox/README.md"
    echo ""
    echo "Quick commands:"
    echo "  - cd /opt/sandbox"
    echo "  - docker ps"
    echo "  - docker-compose up -d"
    echo ""
fi
WELCOME_EOF
chmod +x /etc/profile.d/sandbox-welcome.sh

# Start node-exporter by default
echo "Starting monitoring agent..."
cd /opt/sandbox
docker-compose up -d node-exporter

echo "=== VM6 Initialization Completed ==="
echo "Sandbox environment ready!"
echo "Workspace: /opt/sandbox"
echo "Available tools: Docker, Git, Python3, Node.js, PostgreSQL client, MongoDB client, Redis client"
echo "Node Exporter: http://localhost:9100"
date
