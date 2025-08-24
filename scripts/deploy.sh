#!/bin/bash

# bnbong.xyz 배포 스크립트
# 이 스크립트는 로컬에서 실행하여 서버에 애플리케이션을 배포합니다

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 로그 함수
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 설정 확인
if [ -z "$1" ]; then
    log_error "사용법: $0 <서버_IP> [SSH_USER]"
    echo "예시: $0 192.168.1.100 ubuntu"
    exit 1
fi

SERVER_IP=$1
SSH_USER=${2:-ubuntu}
PROJECT_DIR="/opt/bnbong"
LOCAL_DIR="."

log_info "배포 시작: $SERVER_IP (사용자: $SSH_USER)"

# 1. 로컬 환경 확인
log_info "로컬 환경 확인 중..."

if [ ! -f "docker-compose.yml" ]; then
    log_error "docker-compose.yml 파일을 찾을 수 없습니다."
    exit 1
fi

if [ ! -d "gateway" ] || [ ! -d "auth-server" ] || [ ! -d "client" ] || [ ! -d "playground" ]; then
    log_error "필요한 서비스 디렉토리가 없습니다."
    exit 1
fi

# 2. 서버 연결 확인
log_info "서버 연결 확인 중..."
if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "$SSH_USER@$SERVER_IP" exit 2>/dev/null; then
    log_error "서버에 연결할 수 없습니다. SSH 키 설정을 확인하세요."
    exit 1
fi

# 3. 서버에 프로젝트 디렉토리 생성
log_info "서버에 프로젝트 디렉토리 생성 중..."
ssh "$SSH_USER@$SERVER_IP" "sudo mkdir -p $PROJECT_DIR && sudo chown $SSH_USER:$SSH_USER $PROJECT_DIR"

# 4. 프로젝트 파일 복사
log_info "프로젝트 파일 복사 중..."
rsync -avz --exclude='.git' --exclude='node_modules' --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='.env' --exclude='.DS_Store' --exclude='*.log' \
    "$LOCAL_DIR/" "$SSH_USER@$SERVER_IP:$PROJECT_DIR/"

# 5. 환경 변수 파일 설정
log_info "환경 변수 파일 설정 중..."
ssh "$SSH_USER@$SERVER_IP" "cd $PROJECT_DIR && [ ! -f .env ] && cp .env.example .env 2>/dev/null || echo '.env 파일이 이미 존재합니다.'"

# 6. 서버에서 애플리케이션 빌드 및 실행
log_info "애플리케이션 빌드 및 실행 중..."
ssh "$SSH_USER@$SERVER_IP" "cd $PROJECT_DIR && docker-compose down || true"
ssh "$SSH_USER@$SERVER_IP" "cd $PROJECT_DIR && docker-compose build --no-cache"
ssh "$SSH_USER@$SERVER_IP" "cd $PROJECT_DIR && docker-compose up -d"

# 7. 서비스 상태 확인
log_info "서비스 상태 확인 중..."
sleep 10
ssh "$SSH_USER@$SERVER_IP" "cd $PROJECT_DIR && docker-compose ps"

# 8. 헬스 체크
log_info "헬스 체크 수행 중..."
if ssh "$SSH_USER@$SERVER_IP" "curl -f http://localhost:8000/health" 2>/dev/null; then
    log_info "API Gateway가 정상적으로 실행 중입니다."
else
    log_warn "API Gateway 헬스 체크에 실패했습니다."
fi

if ssh "$SSH_USER@$SERVER_IP" "curl -f http://localhost:8001/health" 2>/dev/null; then
    log_info "Auth Server가 정상적으로 실행 중입니다."
else
    log_warn "Auth Server 헬스 체크에 실패했습니다."
fi

log_info "배포가 완료되었습니다!"
log_info "서버 IP: $SERVER_IP"
log_info "API Gateway: http://$SERVER_IP:8000"
log_info "Auth Server: http://$SERVER_IP:8001"
log_info "Client: http://$SERVER_IP:3000"
log_info "Playground: http://$SERVER_IP:3001"

# 9. 로그 확인 명령어 안내
echo ""
log_info "로그 확인 명령어:"
echo "  ssh $SSH_USER@$SERVER_IP 'cd $PROJECT_DIR && docker-compose logs -f'"
echo "  ssh $SSH_USER@$SERVER_IP 'cd $PROJECT_DIR && docker-compose logs -f [서비스명]'"
echo ""
log_info "서비스 재시작 명령어:"
echo "  ssh $SSH_USER@$SERVER_IP 'cd $PROJECT_DIR && docker-compose restart [서비스명]'"
