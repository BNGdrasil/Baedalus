#!/usr/bin/env bash
# VM2 image deployment script (GHCR release entrypoint)
#
# 운영 배치 위치: /opt/bnbong/deploy-image.sh (권한 755, 소유자 root)
# 호출 주체: Bidar / Bifrost 저장소의 release.yml이 SSH로
#            `sudo /opt/bnbong/deploy-image.sh <service> <image_ref>`를 실행한다.
#
# 설계 요지
#   - 이 스크립트는 소스를 build하지 않는다. GHCR에 이미 올라간 image만 교체한다.
#     현장 build 경로는 deploy.sh가 담당하며, GHCR을 쓸 수 없을 때의 대체 경로다.
#   - flock으로 동시 실행을 막는다. 두 저장소가 같은 시각에 release를 내면
#     .env 갱신과 compose up이 서로 겹칠 수 있기 때문이다.
#   - 교체 직전 컨테이너의 image ID를 rollback/<container>:<UTC> 태그로 남긴다.
#     태그가 아니라 ID를 대상으로 삼아야, 같은 태그가 새 image로 덮여도
#     이전 layer를 되찾을 수 있다.
#   - .env는 통째로 다시 쓰지 않는다. 해당 변수 줄만 바꾸고 나머지는 보존하며,
#     임시 파일에 쓴 뒤 mv로 교체하여 중간 상태가 남지 않게 한다.
#   - health check가 실패하면 .env를 이전 내용으로 되돌리고 이전 image로 다시
#     기동한 뒤 0이 아닌 코드로 종료한다.
#   - docker image prune은 실행하지 않는다. 다른 stack의 image까지 지울 수 있다.
#     대신 rollback/* 태그만 세대 수 기준으로 정리한다.
#
# 사용법
#   release.yml은 build 직후에 digest로 고정한 참조를 넘긴다.
#     sudo /opt/bnbong/deploy-image.sh auth-server ghcr.io/bngdrasil/bidar@sha256:<64자리>
#     sudo /opt/bnbong/deploy-image.sh gateway     ghcr.io/bngdrasil/bifrost@sha256:<64자리>
#   되돌릴 때 쓰는 workflow_dispatch 실행과 손으로 하는 배포는 태그 참조를 넘긴다.
#     sudo /opt/bnbong/deploy-image.sh auth-server ghcr.io/bngdrasil/bidar:sha-1a2b3c4
#     sudo /opt/bnbong/deploy-image.sh gateway     ghcr.io/bngdrasil/bifrost:sha-1a2b3c4
#
#   digest 참조를 기본으로 삼는 이유는, 같은 태그가 registry에서 다른 image로 덮여도
#   실제로 올라간 image가 달라지지 않기 때문이다. compose도 image: name@sha256:... 을
#   그대로 받으므로 .env에는 받은 참조를 손대지 않고 그대로 기록한다.
#
# 환경 변수 (시험용 재정의)
#   DEPLOY_DIR        기본 /opt/bnbong. compose 파일과 .env가 있는 디렉터리다.
#   HEALTH_HOST       기본 127.0.0.1
#   HEALTH_PATH       기본 /health
#   READY_PATH        기본 /ready (gateway에만 적용한다)
#   HEALTH_RETRIES    기본 20
#   HEALTH_INTERVAL   기본 3 (초)
#   ROLLBACK_KEEP     기본 5. 컨테이너마다 남길 rollback 태그 수다.
#   IMAGE_PREFIX      기본 ghcr.io/bngdrasil/. 허용하는 registry와 조직 접두사다.
#                     registry를 옮길 때에만 바꾼다.

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/bnbong}"
ENV_FILE="$DEPLOY_DIR/.env"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
RELEASES_LOG="$DEPLOY_DIR/releases.log"
LOCK_FILE="${LOCK_FILE:-$DEPLOY_DIR/.deploy-image.lock}"

HEALTH_HOST="${HEALTH_HOST:-127.0.0.1}"
HEALTH_PATH="${HEALTH_PATH:-/health}"
READY_PATH="${READY_PATH:-/ready}"
HEALTH_RETRIES="${HEALTH_RETRIES:-20}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-3}"
ROLLBACK_KEEP="${ROLLBACK_KEEP:-5}"
IMAGE_PREFIX="${IMAGE_PREFIX:-ghcr.io/bngdrasil/}"

log()  { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*" >&2; }
err()  { echo "[ERROR] $*" >&2; }

usage() {
    cat <<'USAGE'
usage: deploy-image.sh <auth-server|gateway> <image_ref>

  image_ref : ghcr.io/bngdrasil/<repo>@sha256:<64자리 16진수>  (release 기본)
              ghcr.io/bngdrasil/<repo>:<tag>                   (되돌릴 때)

  auth-server : Bidar   (container vm2-auth,    port 8001, AUTH_SERVER_IMAGE)
  gateway     : Bifrost (container vm2-gateway, port 8000, GATEWAY_IMAGE)
USAGE
}

# ----------------------------------------------------------------------------
# 1. 인자 검증
# ----------------------------------------------------------------------------
if [ "$#" -ne 2 ]; then
    err "인자는 정확히 두 개여야 한다. (받은 개수: $#)"
    usage >&2
    exit 2
fi

SERVICE="$1"
IMAGE_REF="$2"

case "$SERVICE" in
    auth-server)
        CONTAINER="vm2-auth"
        IMAGE_VAR="AUTH_SERVER_IMAGE"
        SERVICE_PORT=8001
        CHECK_READY=0
        ;;
    gateway)
        CONTAINER="vm2-gateway"
        IMAGE_VAR="GATEWAY_IMAGE"
        SERVICE_PORT=8000
        # Bifrost의 /ready는 DB 연결과 서비스 등록부까지 확인한다. /health만 보면
        # 프로세스가 떠 있고 의존 자원이 끊긴 상태를 성공으로 오인한다.
        CHECK_READY=1
        ;;
    *)
        err "알 수 없는 서비스: $SERVICE (auth-server 또는 gateway만 받는다)"
        usage >&2
        exit 2
        ;;
esac

# GHCR의 BNGdrasil 조직 image만 받는다. 이 검사를 두지 않으면 호출자가
# 임의의 registry에서 가져온 image를 운영 컨테이너로 올릴 수 있다.
# IMAGE_PREFIX는 registry를 옮기거나 시험용 registry를 쓸 때에만 바꾼다.
# 접두사는 문자열로 비교하고 나머지 부분만 정규식으로 검사한다. 접두사를 정규식에
# 직접 넣으면 registry 주소의 점과 슬래시를 매번 escape해야 한다.
case "$IMAGE_REF" in
    "$IMAGE_PREFIX"*) ;;
    *)
        err "허용하지 않는 registry 또는 조직이다: $IMAGE_REF"
        err "형식은 ${IMAGE_PREFIX}<repo>@sha256:<64자리 16진수> 또는 ${IMAGE_PREFIX}<repo>:<tag>이다."
        exit 2
        ;;
esac
# 두 가지 표기를 모두 받는다.
#   digest 고정 참조: <prefix><repo>@sha256:<64자리 16진수>
#     release.yml이 build 직후에 넘기는 형식이다. 같은 태그가 나중에 다른 image로
#     덮여도 이 참조는 항상 같은 image를 가리킨다.
#   태그 참조: <prefix><repo>:<tag>
#     되돌릴 때 쓰는 workflow_dispatch 실행이 이 형식을 넘긴다.
IMAGE_NAME_REF="${IMAGE_REF#"$IMAGE_PREFIX"}"
IMAGE_REF_KIND=""
if printf '%s' "$IMAGE_NAME_REF" | grep -Eq '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?@sha256:[0-9a-f]{64}$'; then
    IMAGE_REF_KIND="digest"
elif printf '%s' "$IMAGE_NAME_REF" | grep -Eq '^[a-z0-9]([a-z0-9._-]*[a-z0-9])?:[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'; then
    IMAGE_REF_KIND="tag"
else
    err "image 참조 형식이 올바르지 않다: $IMAGE_REF"
    err "형식은 ${IMAGE_PREFIX}<repo>@sha256:<64자리 16진수> 또는 ${IMAGE_PREFIX}<repo>:<tag>이다."
    exit 2
fi

for f in "$COMPOSE_FILE" "$ENV_FILE"; do
    if [ ! -f "$f" ]; then
        err "필요한 파일이 없다: $f"
        exit 1
    fi
done

for cmd in docker flock curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        err "$cmd 명령을 찾지 못했다."
        exit 1
    fi
done

# ----------------------------------------------------------------------------
# 2. 동시 실행 방지
# ----------------------------------------------------------------------------
# Bidar와 Bifrost의 release가 같은 시각에 도착하면 .env 갱신과 compose up이
# 서로 겹친다. 뒤에 온 쪽을 기다리게 하지 않고 즉시 실패시켜서, 워크플로 로그에
# 무엇 때문에 중단되었는지 남기고 다시 실행하도록 한다.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    err "다른 배포가 진행 중이다($LOCK_FILE). 끝난 뒤에 다시 실행한다."
    exit 1
fi

# compose project 이름은 운영 디렉터리 이름인 bnbong이 된다. --project-directory를
# 명시해야 sudo로 실행할 때 현재 작업 디렉터리에 영향을 받지 않는다.
compose() {
    docker compose --project-directory "$DEPLOY_DIR" -f "$COMPOSE_FILE" "$@"
}

echo "=== VM2 image deployment ==="
log "service   : $SERVICE ($CONTAINER)"
log "image     : $IMAGE_REF"
log "deploy dir: $DEPLOY_DIR"

# ----------------------------------------------------------------------------
# 3. image 내려받기
# ----------------------------------------------------------------------------
log "[1/6] image를 내려받는다."
if ! docker pull "$IMAGE_REF"; then
    err "docker pull에 실패했다: $IMAGE_REF"
    err "GHCR 패키지가 public인지, 태그가 실제로 존재하는지, 아키텍처가 arm64인지 확인한다."
    exit 1
fi

if [ "$IMAGE_REF_KIND" = "digest" ]; then
    # 이미 digest로 고정된 참조다. inspect 결과를 다시 고를 필요가 없으므로
    # 첫 항목을 그대로 쓴다.
    IMAGE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$IMAGE_REF" 2>/dev/null || true)"
    # RepoDigests가 비어 있는 경우에도 받은 참조 자체가 digest이므로 그 값을 남긴다.
    IMAGE_DIGEST="${IMAGE_DIGEST:-$IMAGE_REF}"
else
    # 태그 참조다. 같은 image ID에 여러 repository 태그가 붙어 있을 수 있으므로,
    # 이번에 배포하는 repository의 digest만 골라낸다. 첫 항목을 그대로 쓰면 다른
    # repository의 digest가 기록될 수 있다. `%:*`로 뒤쪽 태그만 떼어 내야
    # registry 주소에 포트가 있는 경우에도 repository 이름이 온전히 남는다.
    IMAGE_DIGEST="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE_REF" \
        | grep -F "${IMAGE_REF%:*}@" | head -n 1 || true)"
    IMAGE_DIGEST="${IMAGE_DIGEST:-(digest 없음)}"
fi
log "digest: $IMAGE_DIGEST"

# ----------------------------------------------------------------------------
# 4. 롤백 지점 확보
# ----------------------------------------------------------------------------
log "[2/6] 롤백 지점을 만든다."
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ROLLBACK_TAG=""
if docker inspect --type container "$CONTAINER" >/dev/null 2>&1; then
    PREV_IMAGE_ID="$(docker inspect --type container --format '{{.Image}}' "$CONTAINER")"
    PREV_IMAGE_REF="$(docker inspect --type container --format '{{.Config.Image}}' "$CONTAINER")"
    ROLLBACK_TAG="rollback/${CONTAINER}:${STAMP}"
    docker tag "$PREV_IMAGE_ID" "$ROLLBACK_TAG"
    log "rollback point: $ROLLBACK_TAG (이전 참조 $PREV_IMAGE_REF)"
else
    warn "$CONTAINER 컨테이너가 없다. 최초 배포로 간주하며 롤백 지점을 만들지 않는다."
fi

# .env는 통째로 되돌릴 수 있도록 사본을 남긴다. 줄 단위로 되돌리면 이번 실행에서
# 건드리지 않은 다른 변경까지 함께 끌려 들어올 수 있다.
ENV_BACKUP="$(mktemp "${ENV_FILE}.bak.XXXXXX")"
chmod 600 "$ENV_BACKUP"
cat "$ENV_FILE" >"$ENV_BACKUP"

cleanup() {
    rm -f "$ENV_BACKUP"
}
trap cleanup EXIT

# ----------------------------------------------------------------------------
# 5. .env의 image 변수 갱신
# ----------------------------------------------------------------------------
log "[3/6] .env의 $IMAGE_VAR 값을 갱신한다."

# 소유자와 권한을 그대로 유지해야 한다. 새로 만든 파일로 바꾸면 root 소유 0644가
# 되어 운영 비밀이 다른 사용자에게 읽힐 수 있다.
update_env_var() {
    local var="$1" value="$2" tmp
    tmp="$(mktemp "${ENV_FILE}.new.XXXXXX")"
    # 원본의 권한과 소유자를 새 파일에 먼저 복사한다.
    chmod --reference="$ENV_FILE" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    chown --reference="$ENV_FILE" "$tmp" 2>/dev/null || true

    if grep -Eq "^[[:space:]]*${var}=" "$ENV_FILE"; then
        # 주석 처리된 예시 줄(`# GATEWAY_IMAGE=...`)은 건드리지 않는다.
        awk -v var="$var" -v val="$value" '
            $0 ~ "^[[:space:]]*" var "=" { print var "=" val; next }
            { print }
        ' "$ENV_FILE" >"$tmp"
    else
        cat "$ENV_FILE" >"$tmp"
        # 파일이 개행으로 끝나지 않으면 새 줄이 앞 줄에 붙는다.
        if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l)" -eq 0 ]; then
            printf '\n' >>"$tmp"
        fi
        printf '%s=%s\n' "$var" "$value" >>"$tmp"
    fi

    mv -f "$tmp" "$ENV_FILE"
}

restore_env() {
    local tmp
    tmp="$(mktemp "${ENV_FILE}.new.XXXXXX")"
    chmod --reference="$ENV_BACKUP" "$tmp" 2>/dev/null || chmod 600 "$tmp"
    chown --reference="$ENV_FILE" "$tmp" 2>/dev/null || true
    cat "$ENV_BACKUP" >"$tmp"
    mv -f "$tmp" "$ENV_FILE"
}

update_env_var "$IMAGE_VAR" "$IMAGE_REF"
log "$IMAGE_VAR=$IMAGE_REF"

# ----------------------------------------------------------------------------
# 6. 컨테이너 교체
# ----------------------------------------------------------------------------
log "[4/6] 컨테이너를 교체한다."
# --no-deps: redis와 auth-server 같은 의존 서비스를 함께 재시작하지 않는다.
# --no-build: GHCR image만 사용한다. 이 자리에서 현장 build가 일어나면
#             release가 가리키는 image와 실제로 뜬 image가 달라진다.
UP_FAILED=0
if ! compose up -d --no-deps --no-build "$SERVICE"; then
    err "docker compose up이 실패했다."
    UP_FAILED=1
fi

# ----------------------------------------------------------------------------
# 7. health 확인
# ----------------------------------------------------------------------------
check_http() {
    local label="$1" url="$2" i
    for ((i = 1; i <= HEALTH_RETRIES; i++)); do
        if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
            log "  OK: $label ($url)"
            return 0
        fi
        sleep "$HEALTH_INTERVAL"
    done
    err "  FAIL: $label ($url)"
    return 1
}

HEALTH_FAILED=0
if [ "$UP_FAILED" -eq 0 ]; then
    log "[5/6] health를 확인한다. (최대 $((HEALTH_RETRIES * HEALTH_INTERVAL))초)"
    check_http "$SERVICE $HEALTH_PATH" "http://${HEALTH_HOST}:${SERVICE_PORT}${HEALTH_PATH}" || HEALTH_FAILED=1
    if [ "$CHECK_READY" -eq 1 ] && [ "$HEALTH_FAILED" -eq 0 ]; then
        # /ready는 DB와 등록부가 준비되지 않으면 503을 돌려준다.
        check_http "$SERVICE $READY_PATH" "http://${HEALTH_HOST}:${SERVICE_PORT}${READY_PATH}" || HEALTH_FAILED=1
    fi
else
    HEALTH_FAILED=1
fi

# ----------------------------------------------------------------------------
# 8. 실패하면 되돌린다
# ----------------------------------------------------------------------------
if [ "$HEALTH_FAILED" -ne 0 ]; then
    err "배포에 실패했다. 이전 상태로 되돌린다."
    restore_env
    log ".env를 이전 내용으로 되돌렸다."

    if [ -n "$ROLLBACK_TAG" ]; then
        if compose up -d --no-deps --no-build "$SERVICE"; then
            log "이전 image로 다시 기동했다."
        else
            err "이전 image로 다시 기동하는 데에도 실패했다. 수동 조치가 필요하다."
            err "  docker image ls 'rollback/${CONTAINER}'"
            err "  cd $DEPLOY_DIR && ${IMAGE_VAR}=$ROLLBACK_TAG docker compose up -d --no-deps $SERVICE"
        fi
        echo ""
        echo "되돌릴 지점: $ROLLBACK_TAG"
    else
        warn "최초 배포라서 되돌릴 image가 없다. 컨테이너 상태를 직접 확인한다."
    fi

    echo ""
    echo "확인 명령"
    echo "  docker logs --tail 100 $CONTAINER"
    echo "  cd $DEPLOY_DIR && docker compose ps"
    exit 1
fi

# ----------------------------------------------------------------------------
# 9. 기록과 정리
# ----------------------------------------------------------------------------
log "[6/6] release 기록을 남기고 rollback 태그를 정리한다."
printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SERVICE" "$IMAGE_REF" "$IMAGE_DIGEST" \
    >>"$RELEASES_LOG"

# docker image prune은 실행하지 않는다. 이 호스트에는 다른 stack의 image도 있고,
# 태그가 없는 중간 layer가 다른 컨테이너의 기반일 수 있다. rollback/* 태그만
# 세대 수를 기준으로 정리한다. 태그가 UTC 시각이므로 사전순 정렬이 곧 시간순이다.
prune_rollback_tags() {
    local repo="rollback/${CONTAINER}" tags count remove
    tags="$(docker image ls --format '{{.Repository}}:{{.Tag}}' "$repo" | sort)"
    [ -n "$tags" ] || return 0
    count="$(printf '%s\n' "$tags" | wc -l | tr -d ' ')"
    if [ "$count" -le "$ROLLBACK_KEEP" ]; then
        return 0
    fi
    remove="$(printf '%s\n' "$tags" | head -n "$((count - ROLLBACK_KEEP))")"
    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        # 태그만 제거한다. 같은 image ID에 다른 태그가 남아 있으면 layer는 유지된다.
        if docker image rm "$tag" >/dev/null 2>&1; then
            log "  오래된 롤백 태그를 제거했다: $tag"
        else
            warn "  롤백 태그를 제거하지 못했다: $tag"
        fi
    done <<<"$remove"
}
prune_rollback_tags

echo ""
echo "=== 배포를 완료했다 ==="
echo "  service : $SERVICE"
echo "  image   : $IMAGE_REF"
echo "  digest  : $IMAGE_DIGEST"
echo "  기록     : $RELEASES_LOG"
echo ""
if [ -n "$ROLLBACK_TAG" ]; then
    echo "이 배포를 되돌리려면 VM2에서 아래를 실행한다."
    echo "  cd $DEPLOY_DIR"
    echo "  sudo sed -i 's|^${IMAGE_VAR}=.*|${IMAGE_VAR}=${ROLLBACK_TAG}|' .env"
    echo "  sudo docker compose up -d --no-deps --no-build $SERVICE"
    echo ""
    echo "남아 있는 롤백 지점은 아래로 확인한다."
    echo "  sudo docker image ls 'rollback/${CONTAINER}'"
fi
