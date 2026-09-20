#!/usr/bin/env bash
#
# VM1 에 nginx-prometheus-exporter 를 systemd 서비스로 설치한다.
# 몇 번을 실행해도 같은 결과가 되며, 바뀐 것이 없으면 서비스를 재시작하지 않는다.
#
#   sudo ./install-nginx-exporter.sh --listen-address 10.0.1.133
#   sudo ./install-nginx-exporter.sh --listen-address 10.0.1.133 --dry-run
#   sudo ./install-nginx-exporter.sh --uninstall
#
# 주요 인자
#   --listen-address <IP>   필수. 이 호스트의 private IP 에만 바인딩한다.
#   --port <포트>            기본값 9113.
#   --allow-from <IP>       Prometheus 가 있는 주소. 기본값은 VM2 의 10.0.1.60 이다.
#   --scrape-uri <URI>      nginx 의 stub_status 주소. 기본값은
#                           http://127.0.0.1:8080/stub_status 이다.
#   --version <버전>         기본값 1.5.3.
#   --dry-run               아무것도 바꾸지 않고 수행할 작업만 출력한다.
#   --uninstall             서비스를 중지하고 유닛과 바이너리를 제거한다.
#
# 먼저 해야 할 일
#   nginx 에 stub_status 를 켜지 않으면 이 exporter 는 지표를 만들지 못한다. VM1 의
#   nginx.conf 는 Bantheon 저장소가 소유하므로 이 저장소에서 고치지 않는다. 필요한
#   설정 조각과 컨테이너 포트 게시 방법은 README.md 의 nginx-exporter 절에 적어 두었다.

set -euo pipefail
umask 022

EX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$EX_SCRIPT_DIR/lib/common.sh"

EX_COMPONENT="nginx-exporter"
ex_enable_cleanup

# --- 기본값 ------------------------------------------------------------------
VERSION="${NGINX_EXPORTER_VERSION:-1.5.3}"
LISTEN_ADDRESS=""
PORT="9113"
ALLOW_FROM="10.0.1.60"
SCRAPE_URI="http://127.0.0.1:8080/stub_status"
SERVICE_USER="nginx_exporter"
BIN_PATH="/usr/local/bin/nginx-prometheus-exporter"
UNIT_NAME="nginx_exporter.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
UNINSTALL=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --listen-address) LISTEN_ADDRESS="${2:-}"; shift 2 ;;
        --port)           PORT="${2:-}"; shift 2 ;;
        --allow-from)     ALLOW_FROM="${2:-}"; shift 2 ;;
        --scrape-uri)     SCRAPE_URI="${2:-}"; shift 2 ;;
        --version)        VERSION="${2:-}"; shift 2 ;;
        --dry-run)        EX_DRY_RUN=1; shift ;;
        --uninstall)      UNINSTALL=1; shift ;;
        -h|--help)        sed -n '2,26p' "$0"; exit 0 ;;
        *) ex_fail "알 수 없는 인자입니다: $1" ;;
    esac
done

ex_require_systemd
ex_require_root

if [ "$UNINSTALL" -eq 1 ]; then
    ex_log "nginx-prometheus-exporter 를 제거합니다. nginx 설정은 건드리지 않습니다."
    ex_remove_unit "$UNIT_NAME" "$UNIT_PATH"
    ex_run rm -f "$BIN_PATH"
    ex_log "제거를 마쳤습니다."
    exit 0
fi

[ -n "$LISTEN_ADDRESS" ] || ex_fail "--listen-address 로 바인딩할 private IP 를 지정해야 합니다. 예: --listen-address 10.0.1.133"
ex_validate_ipv4 "$LISTEN_ADDRESS" || ex_fail "--listen-address 값이 IPv4 주소가 아닙니다: $LISTEN_ADDRESS"
ex_validate_ipv4 "$ALLOW_FROM" || ex_fail "--allow-from 값이 IPv4 주소가 아닙니다: $ALLOW_FROM"
ex_validate_port "$PORT" || ex_fail "--port 값이 포트 번호가 아닙니다: $PORT"
case "$SCRAPE_URI" in
    http://*|https://*) ;;
    *) ex_fail "--scrape-uri 는 http 또는 https 로 시작해야 합니다: $SCRAPE_URI" ;;
esac
case "$LISTEN_ADDRESS" in
    0.0.0.0|127.0.0.1)
        ex_fail "$LISTEN_ADDRESS 에는 바인딩하지 않습니다. 이 호스트의 private IP 를 지정하십시오." ;;
esac

# --- 0. 사전 점검 --------------------------------------------------------------
# 다른 프로세스가 이미 이 포트를 잡고 있으면 유닛만 만들어지고 기동은 실패한다.
# 같은 유닛이 듣고 있는 재설치는 통과한다. node-exporter 와 달리 컨테이너 점검은 하지
# 않는다. VM1 에서 컨테이너로 도는 것은 nginx 자체이고 이 exporter 가 아니기 때문이다.
ex_check_port_free "$PORT" "$UNIT_NAME"

ARCH="$(ex_detect_arch)"
ASSET_NAME="nginx-prometheus-exporter_${VERSION}_linux_${ARCH}.tar.gz"
BASE_URL="https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${VERSION}"
SUMS_NAME="nginx-prometheus-exporter_${VERSION}_checksums.txt"

ex_log "대상 호스트 아키텍처는 $ARCH 이고 설치할 버전은 $VERSION 입니다."
ex_log "바인딩 주소는 ${LISTEN_ADDRESS}:${PORT} 이고 stub_status 주소는 $SCRAPE_URI 입니다."

# stub_status 가 아직 열려 있지 않아도 설치는 진행한다. 다만 그대로 두면 지표가 비므로
# 여기에서 미리 알려 준다.
if ex_have_cmd curl && [ "$EX_DRY_RUN" -eq 0 ]; then
    if ! curl -sf --max-time 5 "$SCRAPE_URI" >/dev/null 2>&1; then
        ex_warn "$SCRAPE_URI 에 응답이 없습니다. nginx 에 stub_status 를 먼저 열어야 지표가 수집됩니다. README.md 를 참고하십시오."
    else
        ex_log "$SCRAPE_URI 가 응답합니다."
    fi
fi

# --- 1. 바이너리 ---------------------------------------------------------------
ex_install_binary "nginx-prometheus-exporter" "$VERSION" \
    "$BASE_URL/$ASSET_NAME" "$BASE_URL/$SUMS_NAME" \
    "$ASSET_NAME" "nginx-prometheus-exporter" "$BIN_PATH"
BINARY_CHANGED="$EX_CHANGED"

# --- 2. 사용자 ----------------------------------------------------------------
ex_ensure_system_user "$SERVICE_USER"

# --- 3. systemd 유닛 -----------------------------------------------------------
ex_write_file "$UNIT_PATH" 0644 <<UNIT
[Unit]
Description=Prometheus NGINX Exporter (BNGdrasil VM1)
Documentation=https://github.com/nginx/nginx-prometheus-exporter
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_PATH \\
  --nginx.scrape-uri=$SCRAPE_URI \\
  --web.listen-address=${LISTEN_ADDRESS}:${PORT}
Restart=on-failure
RestartSec=10
TimeoutStopSec=20

# 하드닝. exporter 는 stub_status 를 읽어 변환할 뿐이므로 특권이 필요하지 않다.
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

# --- 4. 기동과 확인 -------------------------------------------------------------
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
  2) curl -s http://${LISTEN_ADDRESS}:${PORT}/metrics | grep -m1 nginx_up
     nginx_up 값이 1 이어야 stub_status 를 읽고 있다는 뜻입니다.
  3) 값이 0 이면 curl -s $SCRAPE_URI 로 stub_status 자체를 먼저 확인한다.
  4) Prometheus 에 vm1-nginx target 을 추가한다. 조각은 README.md 에 있다.
NEXT
