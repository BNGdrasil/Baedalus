#!/bin/bash
# VM2: Core APIs (Gateway + Auth Server + Redis)
# OCPU: 1, RAM: 6GB
#
# 역할 분리 (DEP-01)
#   이 cloud-init 스크립트는 호스트 준비까지만 담당한다. 구체적으로 Docker 설치,
#   배포 디렉터리 생성, 환경 파일 초기값 작성이 전부다.
#   애플리케이션 release는 baedalus/vm2-deployment/의 docker-compose.yml과
#   deploy.sh가 담당한다. 이전 판은 여기에서 ghcr.io/bngdrasil/*:latest 이미지를
#   쓰는 compose 파일을 직접 만들고 systemd로 기동했는데, 다음 문제가 있었다.
#     - latest 태그는 재부팅마다 다른 버전이 뜰 수 있어 release를 고정하지 못한다.
#     - 실제 VM2는 GHCR 이미지가 아니라 현장 build 이미지를 사용한다.
#     - 생성한 compose가 gateway에 DATABASE_URL을 전달하지 않아 Bifrost가
#       기본 접속 문자열로 되돌아갈 수 있었다.
#   그래서 compose 생성과 systemd 자동 기동을 제거했다. 컨테이너에는
#   `restart: unless-stopped`가 걸려 있으므로 재부팅 후 기동은 Docker가 처리한다.

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
# 실제 소스 디렉터리 이름은 bifrost(Gateway)와 bidar(Auth Server)다.
mkdir -p /opt/bnbong/{bifrost,bidar,bifrost/config}
cd /opt/bnbong

# VM2 자신의 private IP를 미리 구한다. 아래 heredoc은 치환을 허용하는 형태이므로
# awk 안의 $1이 셸 인자로 해석되지 않도록 여기에서 값을 확정해 둔다.
VM2_PRIVATE_IP_VALUE=$(ip -4 -o addr show scope global | awk 'NR==1 {split($4, a, "/"); print a[1]}')

# Create environment file
cat > .env << ENV_EOF
# Environment
ENVIRONMENT=production
DEBUG=false
LOG_LEVEL=INFO

# Domain / CORS
DOMAIN_NAME=${domain_name}
CLIENT_ORIGIN=https://${domain_name}
BACKEND_CORS_ORIGINS=https://${domain_name},https://admin.${domain_name}

# Database (VM3의 호스트 PostgreSQL). 데이터베이스 이름은 bngdrasil이다.
# 이전 판은 bnbong을 적었는데, 실제 운영 DB 이름과 달라서 연결이 실패한다.
POSTGRES_USER=${postgres_user}
POSTGRES_PASSWORD=${postgres_password}
DATABASE_URL=postgresql://${postgres_user}:${postgres_password}@${vm3_private_ip}:5432/bngdrasil

# JWT (Bidar). production에서 32자 미만이거나 예시 문구를 포함하면 기동이 실패한다.
JWT_SECRET_KEY=${jwt_secret_key}
JWT_ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30
REFRESH_TOKEN_EXPIRE_DAYS=7

# Gateway (Bifrost)
# DEP-01: Bifrost에도 DATABASE_URL이 필요하다. 값이 없으면 기본 접속 문자열로
# 되돌아가 엉뚱한 호스트에 연결을 시도한다.
SECRET_KEY=${jwt_secret_key}
ENABLE_METRICS=true
MAX_REQUEST_BODY_BYTES=10485760

# Host 헤더 허용 목록. 비워 두면 Bidar는 기동이 실패하고, Bifrost는 오류 없이
# Host 검사를 건너뛴다. 실제 도메인을 확정한 뒤 값을 좁힌다.
GATEWAY_ALLOWED_HOSTS=api.${domain_name},admin.${domain_name},gateway,localhost,127.0.0.1
AUTH_ALLOWED_HOSTS=api.${domain_name},auth-server,localhost,127.0.0.1
AUTH_ALLOWED_ORIGINS=https://${domain_name},https://admin.${domain_name}

# Network binding (SEC-04)
# VM1 Nginx가 VM2 private IP의 8000/8001로 접근하므로 이 주소에 포트를 게시한다.
# public IP에는 게시하지 않는다.
VM2_PRIVATE_IP=$${VM2_PRIVATE_IP_VALUE}
# VM1의 private IP다. Nginx가 보내는 X-Forwarded-* 헤더만 신뢰하게 한다.
FORWARDED_ALLOW_IPS=10.0.1.133

# 요청 제한
# RATE_LIMIT_PER_MINUTE는 Bifrost 전용이고, Bidar는 로그인 endpoint 전용의
# LOGIN_RATE_LIMIT_PER_MINUTE만 읽는다. 두 값을 혼동하지 않는다.
RATE_LIMIT_PER_MINUTE=60
LOGIN_RATE_LIMIT_PER_MINUTE=10
ENV_EOF

# 애플리케이션 compose 파일은 여기에서 만들지 않는다.
# baedalus/vm2-deployment/deploy.sh가 docker-compose.yml과 소스를 전송한 뒤
# 대상 서비스만 build하여 교체한다. cloud-init 단계에서는 빈 배포 디렉터리와
# 환경 파일 초기값만 준비한다.
echo "Application release is deployed by baedalus/vm2-deployment/deploy.sh"

echo "=== VM2 Initialization Completed ==="
echo "Host prepared. Run baedalus/vm2-deployment/deploy.sh to deploy the application release."
date

