#!/usr/bin/env bash
# deploy-image.sh 설치 스크립트
#
# VM2에서 root 권한으로 한 번만 실행한다. 저장소의 deploy-image.sh를
# /opt/bnbong/deploy-image.sh에 두고, GitHub Actions가 사용할 ubuntu 계정에
# 그 스크립트 하나만 비밀번호 없이 sudo로 실행할 수 있는 권한을 준다.
#
# 사용법
#   scp vm2-deployment/deploy-image.sh vm2-deployment/install-deploy-image.sh ubuntu@<VM2>:/tmp/
#   ssh ubuntu@<VM2> 'sudo bash /tmp/install-deploy-image.sh /tmp/deploy-image.sh'
#
# 여러 번 실행해도 결과가 같다.

set -euo pipefail

SOURCE="${1:-}"
DEPLOY_DIR="${DEPLOY_DIR:-/opt/bnbong}"
TARGET="$DEPLOY_DIR/deploy-image.sh"
DEPLOY_USER="${DEPLOY_USER:-ubuntu}"
SUDOERS_FILE="/etc/sudoers.d/bngdrasil-deploy"

log()  { echo "[INFO]  $*"; }
err()  { echo "[ERROR] $*" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    err "root 권한이 필요하다. sudo로 실행한다."
    exit 1
fi

if [ -z "$SOURCE" ]; then
    err "설치할 deploy-image.sh의 경로를 첫 번째 인자로 지정한다."
    err "  sudo bash install-deploy-image.sh /tmp/deploy-image.sh"
    exit 2
fi

if [ ! -f "$SOURCE" ]; then
    err "원본 파일이 없다: $SOURCE"
    exit 1
fi

if [ ! -d "$DEPLOY_DIR" ]; then
    err "배포 디렉터리가 없다: $DEPLOY_DIR"
    err "VM2의 compose와 .env가 있는 디렉터리를 먼저 확인한다."
    exit 1
fi

if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
    err "사용자가 없다: $DEPLOY_USER"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1. 스크립트 배치
# ----------------------------------------------------------------------------
# 소유자를 root로 두고 쓰기 권한을 root에게만 준다. ubuntu 계정이 이 파일을
# 수정할 수 있으면, sudo NOPASSWD 권한이 사실상 무제한 root 권한이 된다.
log "[1/3] $TARGET에 스크립트를 배치한다."
install -o root -g root -m 755 "$SOURCE" "$TARGET"
log "배치를 마쳤다. $(ls -l "$TARGET")"

# ----------------------------------------------------------------------------
# 2. sudoers 설정
# ----------------------------------------------------------------------------
log "[2/3] $SUDOERS_FILE을 작성한다."
# 인자까지 고정하지 않고 스크립트 경로만 허용한다. 인자 형식 검사는
# deploy-image.sh 자신이 수행하며, sudoers의 명령 인자 일치 규칙으로는
# image 태그처럼 매번 달라지는 값을 표현하기 어렵다.
TMP_SUDOERS="$(mktemp)"
cat >"$TMP_SUDOERS" <<EOF
# BNGdrasil release deployment
# GitHub Actions가 SSH로 접속하여 이 스크립트 하나만 root 권한으로 실행한다.
# 다른 명령에는 비밀번호 없는 sudo를 허용하지 않는다.
$DEPLOY_USER ALL=(root) NOPASSWD: $TARGET
EOF

# 문법이 틀린 파일을 /etc/sudoers.d에 두면 sudo 자체가 동작하지 않는다.
# 반드시 검사한 뒤에 옮긴다.
if ! visudo -cf "$TMP_SUDOERS"; then
    err "sudoers 문법 검사에 실패했다. 파일을 설치하지 않는다."
    rm -f "$TMP_SUDOERS"
    exit 1
fi

install -o root -g root -m 440 "$TMP_SUDOERS" "$SUDOERS_FILE"
rm -f "$TMP_SUDOERS"

# 설치한 뒤 전체 sudoers를 한 번 더 검사한다.
if ! visudo -c >/dev/null; then
    err "설치 후 전체 sudoers 검사에 실패했다. $SUDOERS_FILE을 즉시 확인한다."
    exit 1
fi
log "sudoers 설정을 마쳤다."

# ----------------------------------------------------------------------------
# 3. 확인
# ----------------------------------------------------------------------------
log "[3/3] 설정을 확인한다."
echo ""
echo "허용된 sudo 명령:"
sudo -l -U "$DEPLOY_USER" | sed 's/^/  /'
echo ""
echo "이어서 수행할 작업"
echo "  1) /opt/bnbong/.env에 AUTH_SERVER_IMAGE와 GATEWAY_IMAGE가 있는지 확인한다."
echo "  2) GitHub Actions 전용 SSH 키를 ~$DEPLOY_USER/.ssh/authorized_keys에 등록한다."
echo "  3) 아래 명령이 인자 검증 오류(exit 2)를 돌려주는지 확인한다."
echo "       sudo -u $DEPLOY_USER sudo -n $TARGET"
echo ""
echo "자세한 절차는 저장소의 docs/github-actions-setup.md에 있다."
