#!/usr/bin/env bash
# VM2 Manual Deployment Script
# Deploys Gateway (Bifrost) and Auth Server (Bidar) to VM2.
#
# 설계 요지 (DEP-03)
#   - 전체 stack을 내리지 않는다. 변경한 서비스만 build 후 `up -d --no-deps`로 교체한다.
#   - 다만 최초 배포에는 Redis를 포함한 stack 전체가 필요하므로 --bootstrap 모드를 둔다.
#   - 원격 명령도 `set -euo pipefail`로 실행하고 종료 코드를 그대로 전파한다.
#   - health check가 실패하면 0이 아닌 코드로 종료하고 롤백 방법을 출력한다.
#   - 교체 직전의 image를 롤백 태그로 남긴다.
#   - 운영 `.env`는 읽지도 덮어쓰지도 않는다. 전송 대상에서 제외한다.
#
# 사용법
#   ./deploy.sh --bootstrap          # 최초 배포. redis를 포함한 stack 전체를 기동한다
#   ./deploy.sh                      # gateway, auth-server를 교체한다(재배포)
#   ./deploy.sh gateway              # gateway만 교체한다
#   VM2_HOST=1.2.3.4 ./deploy.sh     # Terraform output 대신 주소를 직접 지정한다
#
# 최초 배포에 --bootstrap이 필요한 이유
#   cloud-init(scripts/user_data_vm2.sh)은 호스트 준비까지만 담당하며 compose 파일을
#   만들지 않는다. 일반 모드는 `up -d --no-deps`로 지정한 서비스만 교체하므로
#   redis 컨테이너를 만들지 않는다. 따라서 새 VM2에서 일반 모드로 시작하면
#   gateway와 auth-server가 redis에 연결하지 못하고 health check도 실패한다.
#   --bootstrap은 `docker compose up -d`로 stack 전체를 한 번 기동한다.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="$(cd "$TERRAFORM_DIR/.." && pwd)"
VM2_USER="${VM2_USER:-ubuntu}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/bnbong}"
HEALTH_RETRIES="${HEALTH_RETRIES:-15}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-4}"

# 배포 모드와 대상 서비스를 정한다.
#   BOOTSTRAP=1 이면 stack 전체를 기동한다(최초 배포).
#   그렇지 않으면 지정한 서비스만 교체하며, 인자가 없으면 두 서비스를 모두 교체한다.
BOOTSTRAP=0
# set -u 환경에서 빈 배열을 참조해도 안전하도록 개수를 따로 센다.
ARGC=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --bootstrap|all) BOOTSTRAP=1 ;;
        -h|--help)
            # 파일 상단의 주석 블록을 그대로 사용법으로 출력한다.
            awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        -*)
            err "알 수 없는 옵션: $arg"
            exit 2
            ;;
        *)
            ARGS[$ARGC]="$arg"
            ARGC=$((ARGC + 1))
            ;;
    esac
done

if [ "$BOOTSTRAP" -eq 1 ]; then
    if [ "$ARGC" -gt 0 ]; then
        err "--bootstrap은 개별 서비스 이름과 함께 쓸 수 없다. stack 전체를 기동하는 모드다."
        exit 2
    fi
    # 최초 배포에서는 소스가 필요한 두 서비스를 모두 전송하고 build한다.
    SERVICES=(auth-server gateway)
elif [ "$ARGC" -gt 0 ]; then
    SERVICES=("${ARGS[@]}")
else
    SERVICES=(auth-server gateway)
fi

for svc in "${SERVICES[@]}"; do
    case "$svc" in
        gateway|auth-server) ;;
        *) err "알 수 없는 서비스: $svc (gateway, auth-server만 지원한다)"; exit 2 ;;
    esac
done

# 롤백 지점과 release 식별에 사용할 태그다. 저장소 HEAD의 짧은 SHA를 우선 쓴다.
release_tag() {
    local dir="$1"
    local sha
    if sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)"; then
        if [ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
            echo "${sha}-dirty"
        else
            echo "$sha"
        fi
    else
        date -u +%Y%m%dT%H%M%SZ
    fi
}

GATEWAY_TAG="$(release_tag "$PROJECT_ROOT/bifrost")"
AUTH_TAG="$(release_tag "$PROJECT_ROOT/bidar")"
GATEWAY_IMAGE="bnbong-gateway:${GATEWAY_TAG}"
AUTH_SERVER_IMAGE="bnbong-auth-server:${AUTH_TAG}"

echo -e "${GREEN}=== VM2 Deployment Script ===${NC}"
log "Project Root: $PROJECT_ROOT"
if [ "$BOOTSTRAP" -eq 1 ]; then
    log "Mode:         bootstrap (stack 전체 기동)"
else
    log "Mode:         rolling replace"
fi
log "Services:     ${SERVICES[*]}"
log "Gateway image:     $GATEWAY_IMAGE"
log "Auth server image: $AUTH_SERVER_IMAGE"
echo ""

# ----------------------------------------------------------------------------
# Step 1. VM2 주소 확인
# ----------------------------------------------------------------------------
log "[1/6] VM2 주소를 확인한다."
if [ -z "${VM2_HOST:-}" ]; then
    if ! VM2_HOST="$(cd "$TERRAFORM_DIR" && terraform output -raw vm2_public_ip 2>/dev/null)"; then
        VM2_HOST=""
    fi
fi
if [ -z "$VM2_HOST" ]; then
    err "VM2 주소를 확인하지 못했다. VM2_HOST 환경 변수로 직접 지정하거나 terraform output을 확인한다."
    exit 1
fi
log "VM2: $VM2_HOST"

# ----------------------------------------------------------------------------
# Step 2. 로컬 환경 확인
# ----------------------------------------------------------------------------
log "[2/6] 로컬 배포 자료를 확인한다."
if [ ! -f "$SCRIPT_DIR/.env" ]; then
    err ".env 파일이 없다. env.template을 복사한 뒤 값을 채운다."
    echo "  cp $SCRIPT_DIR/env.template $SCRIPT_DIR/.env"
    exit 1
fi
for d in bidar bifrost; do
    if [ ! -d "$PROJECT_ROOT/$d" ]; then
        err "소스 디렉터리가 없다: $PROJECT_ROOT/$d"
        exit 1
    fi
done
log "로컬 확인을 마쳤다."

# ----------------------------------------------------------------------------
# Step 3. 원격 디렉터리 준비
# ----------------------------------------------------------------------------
log "[3/6] VM2의 배포 디렉터리를 준비한다."
ssh "$VM2_USER@$VM2_HOST" "set -euo pipefail; sudo mkdir -p '$DEPLOY_DIR'/{bidar,bifrost,bifrost/config} && sudo chown -R '$VM2_USER':'$VM2_USER' '$DEPLOY_DIR'"

# 일반 모드는 redis를 만들지 않는다. 최초 배포에 --bootstrap을 쓰지 않으면
# gateway와 auth-server가 연결할 redis가 없는 상태로 기동되므로, 여기에서 먼저
# 컨테이너 존재 여부를 확인하고 없으면 무엇을 해야 하는지 알린 뒤 중단한다.
if [ "$BOOTSTRAP" -eq 0 ]; then
    log "redis 컨테이너 존재 여부를 확인한다."
    if ! ssh "$VM2_USER@$VM2_HOST" "sudo docker inspect vm2-redis >/dev/null 2>&1"; then
        err "VM2에 vm2-redis 컨테이너가 없다."
        err "일반 모드는 지정한 서비스만 교체하므로 redis를 만들지 않는다."
        err "최초 배포라면 아래 명령으로 stack 전체를 먼저 기동한다."
        echo ""
        echo "  ./deploy.sh --bootstrap"
        echo ""
        exit 1
    fi
    log "vm2-redis를 확인했다."
fi

# ----------------------------------------------------------------------------
# Step 4. 소스 전송
# ----------------------------------------------------------------------------
log "[4/6] 소스를 전송한다."
RSYNC_EXCLUDES=(
    --exclude='.git'
    --exclude='.venv'
    --exclude='__pycache__'
    --exclude='.pytest_cache'
    --exclude='.mypy_cache'
    --exclude='htmlcov'
    --exclude='.env'
)

for svc in "${SERVICES[@]}"; do
    case "$svc" in
        auth-server)
            log "  - Bidar (Auth Server) 전송"
            rsync -avz "${RSYNC_EXCLUDES[@]}" "$PROJECT_ROOT/bidar/" "$VM2_USER@$VM2_HOST:$DEPLOY_DIR/bidar/"
            ;;
        gateway)
            log "  - Bifrost (Gateway) 전송"
            rsync -avz "${RSYNC_EXCLUDES[@]}" "$PROJECT_ROOT/bifrost/" "$VM2_USER@$VM2_HOST:$DEPLOY_DIR/bifrost/"
            ;;
    esac
done

log "  - compose 파일 전송"
rsync -avz "$SCRIPT_DIR/docker-compose.yml" "$VM2_USER@$VM2_HOST:$DEPLOY_DIR/"

# 운영 .env는 전송하지 않는다. 서버에 이미 있는 값이 원본이며, 로컬 파일로 덮어쓰면
# 운영 비밀이 사라질 수 있다. 변수 추가가 필요하면 서버에서 직접 편집한다.
log "  - .env는 전송 대상에서 제외한다(운영 환경 파일 보호)."

# ----------------------------------------------------------------------------
# Step 5. build 후 해당 서비스만 교체
# ----------------------------------------------------------------------------
if [ "$BOOTSTRAP" -eq 1 ]; then
    log "[5/6] 이미지를 build하고 stack 전체를 기동한다(bootstrap)."
else
    log "[5/6] 이미지를 build하고 대상 서비스를 교체한다."
fi
# 원격 셸이 값을 단어로 쪼개지 않도록 각 변수를 작은따옴표로 감싸서 전달한다.
ssh "$VM2_USER@$VM2_HOST" \
    "GATEWAY_IMAGE='$GATEWAY_IMAGE' \
     AUTH_SERVER_IMAGE='$AUTH_SERVER_IMAGE' \
     DEPLOY_DIR='$DEPLOY_DIR' \
     SERVICES='${SERVICES[*]}' \
     BOOTSTRAP='$BOOTSTRAP' \
     bash -s" <<'ENDSSH'
set -euo pipefail

cd "$DEPLOY_DIR"

export GATEWAY_IMAGE AUTH_SERVER_IMAGE

# 교체 직전 image를 롤백 태그로 남긴다.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
for container in vm2-gateway vm2-auth; do
    if sudo docker inspect --format '{{.Image}}' "$container" >/dev/null 2>&1; then
        prev="$(sudo docker inspect --format '{{.Config.Image}}' "$container")"
        sudo docker tag "$prev" "rollback/${container}:${STAMP}"
        echo "  - rollback point: rollback/${container}:${STAMP} (from ${prev})"
    fi
done

echo "  - building: $SERVICES"
# shellcheck disable=SC2086
sudo -E docker compose build $SERVICES

if [ "$BOOTSTRAP" = "1" ]; then
    # 최초 배포에서는 redis를 포함한 stack 전체를 기동한다. 여기에서만 의존 서비스가
    # 만들어지므로, 이 단계를 건너뛰면 새 VM2에 redis 컨테이너가 생기지 않는다.
    echo "  - bootstrap: starting the whole stack"
    sudo -E docker compose up -d
else
    echo "  - replacing: $SERVICES"
    # --no-deps: 의존 서비스(redis, auth-server)를 함께 재시작하지 않는다.
    # shellcheck disable=SC2086
    sudo -E docker compose up -d --no-deps $SERVICES
fi

sudo docker compose ps
ENDSSH

# ----------------------------------------------------------------------------
# Step 6. health check
# ----------------------------------------------------------------------------
log "[6/6] health check를 수행한다."

check_http() {
    local name="$1" url="$2" i
    for ((i = 1; i <= HEALTH_RETRIES; i++)); do
        if ssh "$VM2_USER@$VM2_HOST" "curl -sf --max-time 5 '$url' >/dev/null"; then
            log "  OK: $name"
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
    done
    err "  FAIL: $name ($url)"
    return 1
}

FAILED=0
for svc in "${SERVICES[@]}"; do
    case "$svc" in
        gateway)     check_http "Gateway (8000)"     "http://127.0.0.1:8000/health" || FAILED=1 ;;
        auth-server) check_http "Auth Server (8001)" "http://127.0.0.1:8001/health" || FAILED=1 ;;
    esac
done

if ! ssh "$VM2_USER@$VM2_HOST" "sudo docker exec vm2-redis redis-cli ping | grep -q PONG"; then
    err "  FAIL: Redis ping (vm2-redis)"
    err "  컨테이너 자체가 없다면 ./deploy.sh --bootstrap으로 stack 전체를 먼저 기동한다."
    FAILED=1
else
    log "  OK: Redis"
fi

if [ "$FAILED" -ne 0 ]; then
    err "배포 후 health check가 실패했다. 아래 절차로 이전 image로 되돌린다."
    echo ""
    echo "  ssh $VM2_USER@$VM2_HOST"
    echo "  sudo docker image ls 'rollback/*'        # 되돌릴 태그를 고른다"
    echo "  cd $DEPLOY_DIR"
    echo "  sudo GATEWAY_IMAGE=<rollback tag> docker compose up -d --no-deps gateway"
    echo ""
    exit 1
fi

echo ""
echo -e "${GREEN}=== VM2 Deployment Completed ===${NC}"
echo ""
echo "배포한 서비스: ${SERVICES[*]}"
echo "  - Gateway (Bifrost):   $GATEWAY_IMAGE"
echo "  - Auth Server (Bidar): $AUTH_SERVER_IMAGE"
echo ""
echo "외부 접근 경로는 VM1 Nginx(https://api.bnbong.com)이다. VM2의 8000/8001 포트는"
echo "private IP와 loopback에만 게시하므로 public IP로 직접 접근하지 않는다."
echo ""
echo "로그 확인:"
echo "  ssh $VM2_USER@$VM2_HOST 'cd $DEPLOY_DIR && sudo docker compose logs -f'"
