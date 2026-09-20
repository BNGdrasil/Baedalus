#!/usr/bin/env bash
#
# VM3 에 postgres_exporter 를 systemd 서비스로 설치한다.
# 몇 번을 실행해도 같은 결과가 되며, 바뀐 것이 없으면 서비스를 재시작하지 않는다.
#
#   sudo ./install-postgres-exporter.sh --listen-address 10.0.2.134
#   sudo ./install-postgres-exporter.sh --listen-address 10.0.2.134 --dry-run
#   sudo ./install-postgres-exporter.sh --listen-address 10.0.2.134 --name legacy14 --port 9188
#   sudo ./install-postgres-exporter.sh --uninstall
#
# 주요 인자
#   --listen-address <IP>   필수. 이 호스트의 private IP 에만 바인딩한다.
#   --port <포트>            기본값 9187.
#   --allow-from <IP>       Prometheus 가 있는 주소. 기본값은 VM2 의 10.0.1.60 이다.
#   --name <이름>            한 호스트에 여러 클러스터를 관측할 때 붙이는 구분자.
#                           지정하면 유닛과 환경 파일 이름에 그 이름이 들어간다.
#   --env-file <경로>        DSN 을 담은 root 전용 환경 파일. 기본 경로는 아래와 같다.
#   --version <버전>         기본값 0.20.1.
#   --dry-run               아무것도 바꾸지 않고 수행할 작업만 출력한다.
#   --uninstall             서비스를 중지하고 유닛과 바이너리를 제거한다.
#
# 비밀 값을 다루는 방식
#   - 이 스크립트는 비밀번호를 인자로 받지 않는다. DSN 은 0600 권한에 소유자가 root 인
#     환경 파일에만 두고, systemd 가 EnvironmentFile 로 읽어 프로세스 환경에 넣는다.
#   - 따라서 ps 나 /proc/<pid>/cmdline 에 DSN 이 노출되지 않는다.
#   - 환경 파일이 없으면 템플릿을 만들고 서비스는 기동하지 않는다. 값을 채운 뒤에
#     같은 명령을 다시 실행하면 그때 기동한다.

set -euo pipefail
umask 022

EX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$EX_SCRIPT_DIR/lib/common.sh"

EX_COMPONENT="postgres-exporter"
ex_enable_cleanup

# --- 기본값 ------------------------------------------------------------------
VERSION="${POSTGRES_EXPORTER_VERSION:-0.20.1}"
LISTEN_ADDRESS=""
PORT="9187"
ALLOW_FROM="10.0.1.60"
INSTANCE_NAME=""
ENV_FILE=""
CONFIG_DIR="/etc/bngdrasil-exporters"
SERVICE_USER="postgres_exporter"
BIN_PATH="/usr/local/bin/postgres_exporter"
UNINSTALL=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --listen-address) LISTEN_ADDRESS="${2:-}"; shift 2 ;;
        --port)           PORT="${2:-}"; shift 2 ;;
        --allow-from)     ALLOW_FROM="${2:-}"; shift 2 ;;
        --name)           INSTANCE_NAME="${2:-}"; shift 2 ;;
        --env-file)       ENV_FILE="${2:-}"; shift 2 ;;
        --version)        VERSION="${2:-}"; shift 2 ;;
        --dry-run)        EX_DRY_RUN=1; shift ;;
        --uninstall)      UNINSTALL=1; shift ;;
        -h|--help)        sed -n '2,30p' "$0"; exit 0 ;;
        *) ex_fail "알 수 없는 인자입니다: $1" ;;
    esac
done

# --name 을 붙이면 유닛과 환경 파일 이름이 함께 갈린다. 5433 에 남겨 둔 이전 세대
# 클러스터를 따로 관측할 때 사용한다.
case "$INSTANCE_NAME" in
    '') UNIT_BASE="postgres_exporter"; ENV_BASE="postgres-exporter" ;;
    *[!a-zA-Z0-9_-]*) ex_fail "--name 에는 영문자와 숫자와 밑줄과 붙임표만 사용할 수 있습니다: $INSTANCE_NAME" ;;
    *)  UNIT_BASE="postgres_exporter-$INSTANCE_NAME"; ENV_BASE="postgres-exporter-$INSTANCE_NAME" ;;
esac
UNIT_NAME="$UNIT_BASE.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
[ -n "$ENV_FILE" ] || ENV_FILE="$CONFIG_DIR/$ENV_BASE.env"

ex_require_systemd
ex_require_root

if [ "$UNINSTALL" -eq 1 ]; then
    ex_log "postgres_exporter 를 제거합니다. 환경 파일과 데이터베이스 역할은 그대로 둡니다."
    ex_remove_unit "$UNIT_NAME" "$UNIT_PATH"
    # 같은 바이너리를 다른 인스턴스가 함께 쓰고 있을 수 있으므로, 남은 유닛이 없을
    # 때에만 바이너리를 지운다.
    if ls /etc/systemd/system/postgres_exporter*.service >/dev/null 2>&1; then
        ex_log "다른 postgres_exporter 유닛이 남아 있으므로 $BIN_PATH 는 지우지 않습니다."
    else
        ex_run rm -f "$BIN_PATH"
    fi
    ex_log "제거를 마쳤습니다. 환경 파일 $ENV_FILE 과 역할 bngdrasil_exporter 는 남아 있습니다."
    exit 0
fi

[ -n "$LISTEN_ADDRESS" ] || ex_fail "--listen-address 로 바인딩할 private IP 를 지정해야 합니다. 예: --listen-address 10.0.2.134"
ex_validate_ipv4 "$LISTEN_ADDRESS" || ex_fail "--listen-address 값이 IPv4 주소가 아닙니다: $LISTEN_ADDRESS"
ex_validate_ipv4 "$ALLOW_FROM" || ex_fail "--allow-from 값이 IPv4 주소가 아닙니다: $ALLOW_FROM"
ex_validate_port "$PORT" || ex_fail "--port 값이 포트 번호가 아닙니다: $PORT"
case "$LISTEN_ADDRESS" in
    0.0.0.0|127.0.0.1)
        ex_fail "$LISTEN_ADDRESS 에는 바인딩하지 않습니다. 이 호스트의 private IP 를 지정하십시오." ;;
esac

# --- 0. 사전 점검 --------------------------------------------------------------
# 다른 프로세스가 이미 이 포트를 잡고 있으면 유닛만 만들어지고 기동은 실패한다.
# --name 으로 인스턴스를 나누면 유닛 이름도 함께 갈리므로, 같은 유닛이 듣고 있는
# 재설치만 통과하고 다른 인스턴스와 포트가 겹치면 여기에서 걸린다.
ex_check_port_free "$PORT" "$UNIT_NAME"

ARCH="$(ex_detect_arch)"
ASSET_NAME="postgres_exporter-${VERSION}.linux-${ARCH}.tar.gz"
BASE_URL="https://github.com/prometheus-community/postgres_exporter/releases/download/v${VERSION}"

ex_log "대상 호스트 아키텍처는 $ARCH 이고 설치할 버전은 $VERSION 입니다."
ex_log "바인딩 주소는 ${LISTEN_ADDRESS}:${PORT} 이고 수집을 허용할 주소는 $ALLOW_FROM 입니다."

# --- 1. 바이너리 ---------------------------------------------------------------
ex_install_binary "postgres_exporter" "$VERSION" \
    "$BASE_URL/$ASSET_NAME" "$BASE_URL/sha256sums.txt" \
    "$ASSET_NAME" "postgres_exporter" "$BIN_PATH"
BINARY_CHANGED="$EX_CHANGED"

# --- 2. 사용자 ----------------------------------------------------------------
ex_ensure_system_user "$SERVICE_USER"

# --- 3. 환경 파일 --------------------------------------------------------------
# 이미 있는 파일은 절대 덮어쓰지 않는다. 여기에 실제 비밀번호가 들어 있기 때문이다.
ENV_READY=1
if [ -f "$ENV_FILE" ]; then
    ex_log "$ENV_FILE 이 이미 있으므로 덮어쓰지 않습니다."
    ex_run chmod 0600 "$ENV_FILE"
    ex_run chown root:root "$ENV_FILE"
    if grep -q 'PUT-PASSWORD-HERE' "$ENV_FILE" 2>/dev/null; then
        ex_warn "$ENV_FILE 에 아직 자리 표시 문자열이 남아 있습니다. 실제 비밀번호로 바꾸어야 합니다."
        ENV_READY=0
    fi
elif [ "$EX_DRY_RUN" -eq 1 ]; then
    ex_log "(dry-run) $ENV_FILE 템플릿을 권한 0600 으로 만듭니다."
    ENV_READY=0
else
    ex_run install -d -m 0700 -o root -g root "$(dirname "$ENV_FILE")"
    umask 077
    cat > "$ENV_FILE" <<'ENVTPL'
# postgres_exporter 가 사용할 접속 문자열. 이 파일은 권한 0600, 소유자 root 여야 한다.
# systemd 가 EnvironmentFile 로 읽어 프로세스 환경에 넣으므로 명령 인자에 노출되지 않는다.
#
# 역할과 비밀번호는 postgres-exporter-role.sql 로 만들고 psql 의 \password 로 지정한다.
# 비밀번호에 @ 나 : 나 / 같은 문자가 있으면 퍼센트 인코딩해야 한다.
# PostgreSQL 17 은 5432, 이전 세대인 14 는 5433 에 있다.
DATA_SOURCE_NAME=postgresql://bngdrasil_exporter:PUT-PASSWORD-HERE@127.0.0.1:5432/postgres?sslmode=disable
ENVTPL
    umask 022
    chmod 0600 "$ENV_FILE"
    chown root:root "$ENV_FILE"
    ex_log "$ENV_FILE 템플릿을 만들었습니다. 비밀번호를 채운 뒤 이 스크립트를 다시 실행하십시오."
    ENV_READY=0
fi

# --- 4. systemd 유닛 -----------------------------------------------------------
ex_write_file "$UNIT_PATH" 0644 <<UNIT
[Unit]
Description=Prometheus PostgreSQL Exporter (BNGdrasil VM3)
Documentation=https://github.com/prometheus-community/postgres_exporter
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
# DSN 은 인자가 아니라 이 환경 파일에서만 온다. 따라서 ps 출력에 남지 않는다.
EnvironmentFile=$ENV_FILE
ExecStart=$BIN_PATH --web.listen-address=${LISTEN_ADDRESS}:${PORT}
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

# 하드닝. exporter 는 통계만 읽으므로 쓰기 권한과 특권을 모두 떨어뜨린다.
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectClock=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectProc=invisible
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
# 방화벽과 별개로 접근 가능한 대역을 한 겹 더 좁힌다. 커널이 cgroup BPF 를 지원하지
# 않으면 systemd 가 경고만 남기고 무시하므로, 이 설정만 믿지 말고 방화벽도 확인한다.
IPAddressDeny=any
IPAddressAllow=localhost
# 이 호스트에서 자기 자신의 private IP 로 확인 조회를 할 때에는 출발지 주소가
# loopback 이 아니라 아래 주소가 된다. 그래서 검증 명령이 막히지 않도록 함께 허용한다.
IPAddressAllow=$LISTEN_ADDRESS
IPAddressAllow=$ALLOW_FROM

[Install]
WantedBy=multi-user.target
UNIT
UNIT_CHANGED="$EX_CHANGED"

# --- 5. 기동과 확인 -------------------------------------------------------------
if [ "$ENV_READY" -eq 0 ]; then
    ex_warn "환경 파일이 아직 준비되지 않았으므로 $UNIT_NAME 을 기동하지 않았습니다."
    cat <<PENDING

[$EX_COMPONENT] 환경 파일을 채우는 순서는 다음과 같습니다.
  1) sudo -u postgres psql -p 5432 -f $EX_SCRIPT_DIR/postgres-exporter-role.sql
  2) sudo -u postgres psql -p 5432 -c '\\password bngdrasil_exporter'
  3) sudo vi $ENV_FILE 로 PUT-PASSWORD-HERE 를 실제 비밀번호로 바꾼다.
  4) 이 스크립트를 같은 인자로 다시 실행한다.
PENDING
    exit 0
fi

NEEDS_RESTART=0
if [ "$BINARY_CHANGED" -eq 1 ] || [ "$UNIT_CHANGED" -eq 1 ]; then
    NEEDS_RESTART=1
fi
ex_apply_unit "$UNIT_NAME" "$NEEDS_RESTART"
ex_check_metrics "$LISTEN_ADDRESS" "$PORT" || true

ex_firewall_hint "$PORT" "$LISTEN_ADDRESS" "$ALLOW_FROM"

cat <<NEXT

[$EX_COMPONENT] 다음 단계를 직접 확인하십시오.
  1) systemctl status $UNIT_NAME
  2) curl -s http://${LISTEN_ADDRESS}:${PORT}/metrics | grep -m1 pg_up
     pg_up 값이 1 이어야 접속과 권한이 모두 정상입니다.
  3) 값이 0 이면 journalctl -u $UNIT_NAME -n 50 으로 접속 오류를 확인한다.
  4) Prometheus 에 vm3-postgres target 을 추가한다. 조각은 README.md 에 있다.
NEXT
