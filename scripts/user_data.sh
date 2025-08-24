#!/bin/bash

# Update system
apt-get update
apt-get upgrade -y

# Install Docker
apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/v2.20.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create application directory
mkdir -p /opt/bnbong
cd /opt/bnbong

# Create environment file
cat > .env << EOF
# Environment
ENVIRONMENT=production
DEBUG=false
LOG_LEVEL=INFO

# Database
POSTGRES_USER=bnbong
POSTGRES_PASSWORD=your-secure-password-here
DATABASE_URL=postgresql://bnbong:your-secure-password-here@postgres:5432/bnbong

# JWT
JWT_SECRET_KEY=your-super-secret-jwt-key-change-this-in-production

# Redis
REDIS_URL=redis://redis:6379/0

# Domain
DOMAIN_NAME=${domain_name}
EOF

# Clone or copy the application repository
# For production, you should use a proper CI/CD pipeline or git clone
# This is a basic setup - you can replace this with your actual deployment method

# Create nginx directory structure
mkdir -p nginx/ssl

# Create a basic docker-compose.yml for initial setup
# This will be replaced by the actual file during deployment
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  # Placeholder for actual services
  # This will be replaced during deployment
  placeholder:
    image: nginx:alpine
    ports:
      - "80:80"
    command: ["echo", "Waiting for deployment..."]
EOF

# Start services
docker-compose up -d

# Enable Docker service
systemctl enable docker
systemctl start docker

# Create systemd service for auto-restart
cat > /etc/systemd/system/bnbong.service << EOF
[Unit]
Description=Bnbong Application
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
EOF

# Enable and start the service
systemctl enable bnbong.service
systemctl start bnbong.service

echo "Setup completed successfully!"
