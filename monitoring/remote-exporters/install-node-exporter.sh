#!/usr/bin/env bash
#
# VM1 과 VM3 에 node_exporter 를 systemd 서비스로 설치한다.
# 몇 번을 실행해도 같은 결과가 되며, 바뀐 것이 없으면 서비스를 재시작하지 않는다.
#
#   sudo ./install-node-exporter.sh --listen-address 10.0.1.133
#   sudo ./install-node-exporter.sh --listen-address 10.0.2.134 --dry-run
#   sudo ./install-node-exporter.sh --listen-address 10.0.1.133 --uninstall
#
# 주요 인자
#   --listen-address <IP>   필수. 이 호스트의 private IP 에만 바인딩한다.
#   --port <포트>            기본값 9100.
#   --allow-from <IP>       Prometheus 가 있는 주소. 기본값은 VM2 의 10.0.1.60 이다.
#   --textfile-dir <경로>    backup/lib/common.sh 의 METRICS_DIR 과 같아야 한다.
#   --version <버전>         기본값 1.9.1. VM2 compose 의 node-exporter 태그와 맞춘다.
#   --dry-run               아무것도 바꾸지 않고 수행할 작업만 출력한다.
#   --uninstall             서비스를 중지하고 유닛과 바이너리를 제거한다.
#
# 설계 요지
#   - 버전을 고정하고, 체크섬은 릴리스의 sha256sums.txt 를 내려받아 대조한다.
#   - 전용 시스템 사용자로 실행하며 systemd 하드닝 옵션을 붙인다.
#   - 0.0.0.0 에 바인딩하지 않는다. 9100 은 Prometheus 호스트에서만 닿아야 한다.
#   - 방화벽(iptables, ufw, OCI security list)은 바꾸지 않고 필요한 규칙만 안내한다.

set -euo pipefail
umask 022

EX_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$EX_SCRIPT_DIR/lib/common.sh"

EX_COMPONENT="node-exporter"
ex_enable_cleanup

# --- 기본값 ------------------------------------------------------------------
VERSION="${NODE_EXPORTER_VERSION:-1.9.1}"
LISTEN_ADDRESS=""
PORT="9100"
ALLOW_FROM="10.0.1.60"
# backup/lib/common.sh 의 METRICS_DIR 기본값과 같은 경로다. 이 값이 어긋나면 VM3 의
# 백업 지표가 Prometheus 에 올라오지 않고 BackupStale 경보가 잘못 울린다.
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
SERVICE_USER="node_exporter"
BIN_PATH="/usr/local/bin/node_exporter"
UNIT_NAME="node_exporter.service"
UNIT_PATH="/etc/systemd/system/$UNIT_NAME"
UNINSTALL=0

# --- 인자 --------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --listen-address) LISTEN_ADDRESS="${2:-}"; shift 2 ;;
        --port)           PORT="${2:-}"; shift 2 ;;
        --allow-from)     ALLOW_FROM="${2:-}"; shift 2 ;;
        --textfile-dir)   TEXTFILE_DIR="${2:-}"; shift 2 ;;
        --version)        VERSION="${2:-}"; shift 2 ;;
        --dry-run)        EX_DRY_RUN=1; shift ;;
        --uninstall)      UNINSTALL=1; shift ;;
        -h|--help)        sed -n '2,25p' "$0"; exit 0 ;;
        *) ex_fail "알 수 없는 인자입니다: $1" ;;
    esac
done

ex_require_systemd
ex_require_root

if [ "$UNINSTALL" -eq 1 ]; then
    ex_log "node_exporter 를 제거합니다. textfile collector 디렉터리와 그 안의 지표 파일은 지우지 않습니다."
    ex_remove_unit "$UNIT_NAME" "$UNIT_PATH"
    ex_run rm -f "$BIN_PATH"
    ex_log "제거를 마쳤습니다. 시스템 사용자 $SERVICE_USER 는 다른 용도로 남아 있을 수 있으므로 지우지 않았습니다."
    exit 0
fi

[ -n "$LISTEN_ADDRESS" ] || ex_fail "--listen-address 로 바인딩할 private IP 를 지정해야 합니다. 예: --listen-address 10.0.1.133"
ex_validate_ipv4 "$LISTEN_ADDRESS" || ex_fail "--listen-address 값이 IPv4 주소가 아닙니다: $LISTEN_ADDRESS"
ex_validate_ipv4 "$ALLOW_FROM" || ex_fail "--allow-from 값이 IPv4 주소가 아닙니다: $ALLOW_FROM"
ex_validate_port "$PORT" || ex_fail "--port 값이 포트 번호가 아닙니다: $PORT"
case "$LISTEN_ADDRESS" in
    0.0.0.0|127.0.0.1)
        ex_fail "$LISTEN_ADDRESS 에는 바인딩하지 않습니다. 이 호스트의 private IP 를 지정하십시오." ;;
esac
case "$TEXTFILE_DIR" in
    /*) ;;
    *) ex_fail "--textfile-dir 은 절대 경로여야 합니다: $TEXTFILE_DIR" ;;
esac

# 지정한 주소가 이 호스트에 실제로 있는지 확인한다. 없는 주소에 바인딩하면 유닛이
# 기동에 실패하며, 그 원인은 로그를 열기 전까지 드러나지 않는다.
if ex_have_cmd ip; then
    if ! ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$LISTEN_ADDRESS"; then
        ex_warn "$LISTEN_ADDRESS 가 이 호스트의 인터페이스에서 보이지 않습니다. 주소를 다시 확인하십시오."
    fi
fi

# --- 0. 사전 점검 --------------------------------------------------------------
# 바이너리를 내려받기 전에 호스트 상태를 먼저 본다. 2026-09-19 에 VM1 과 VM3 에 올린
# node-exporter 컨테이너가 9100 을 잡고 있는 상태에서 이 스크립트를 그대로 돌리면,
# 유닛은 만들어지지만 기동에 실패하고 수집은 컨테이너가 계속 담당하게 된다. 그러면
# 어느 쪽이 지표를 내는지 사람이 알기 어려워진다. 우회 플래그는 두지 않았다.
ex_check_port_free "$PORT" "$UNIT_NAME"
ex_check_no_docker_exporter "node-exporter" "prom/node-exporter"

ARCH="$(ex_detect_arch)"
ASSET_NAME="node_exporter-${VERSION}.linux-${ARCH}.tar.gz"
BASE_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}"

ex_log "대상 호스트 아키텍처는 $ARCH 이고 설치할 버전은 $VERSION 입니다."
ex_log "바인딩 주소는 ${LISTEN_ADDRESS}:${PORT} 이고 수집을 허용할 주소는 $ALLOW_FROM 입니다."

# --- 1. 바이너리 ---------------------------------------------------------------
ex_install_binary "node_exporter" "$VERSION" \
    "$BASE_URL/$ASSET_NAME" "$BASE_URL/sha256sums.txt" \
    "$ASSET_NAME" "node_exporter" "$BIN_PATH"
BINARY_CHANGED="$EX_CHANGED"

# --- 2. 사용자와 디렉터리 --------------------------------------------------------
ex_ensure_system_user "$SERVICE_USER"

# textfile collector 디렉터리는 root 가 쓰고 exporter 가 읽는다. 백업 스크립트는 root 로
# 돌면서 .prom 파일을 0644 로 남기므로 디렉터리는 0755 로 둔다.
ex_run install -d -m 0755 -o root -g root "$TEXTFILE_DIR"
ex_log "textfile collector 디렉터리를 확인했습니다: $TEXTFILE_DIR"

# 디렉터리 자신이 0755 여도 상위 경로가 0700 이면 비root 서비스 사용자는 지나갈 수 없다.
# VM3 의 /var/lib/node_exporter 가 실제로 0700 이므로 여기에서 함께 고친다.
ex_ensure_traversable "$TEXTFILE_DIR"

# --- 3. systemd 유닛 -----------------------------------------------------------
ex_write_file "$UNIT_PATH" 0644 <<UNIT
[Unit]
Description=Prometheus Node Exporter (BNGdrasil 원격 호스트 지표)
Documentation=https://github.com/prometheus/node_exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
ExecStart=$BIN_PATH \\
  --web.listen-address=${LISTEN_ADDRESS}:${PORT} \\
  --collector.textfile.directory=$TEXTFILE_DIR \\
  --collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run/containerd|var/lib/docker/.+)(\$|/) \\
  --collector.filesystem.fs-types-exclude=^(autofs|binfmt_misc|cgroup2?|configfs|debugfs|devpts|devtmpfs|fusectl|hugetlbfs|mqueue|overlay|proc|pstore|securityfs|sysfs|tracefs)\$
Restart=on-failure
RestartSec=5
TimeoutStopSec=20

# 하드닝. node_exporter 는 읽기만 하므로 쓰기 권한과 특권을 모두 떨어뜨린다.
NoNewPrivileges=yes
CapabilityBoundingSet=
AmbientCapabilities=
ProtectSystem=strict
# 홈 디렉터리를 완전히 가리면 그 아래 마운트의 용량 지표가 빠지므로 읽기 전용으로 둔다.
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
ProtectClock=yes
ProtectHostname=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
ProtectProc=default
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
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
# textfile 지표는 서비스 사용자가 디렉터리를 읽을 수 있어야만 나온다. 읽지 못하면
# node_exporter 는 조용히 빈 결과를 내므로, 여기에서 확인하고 실패하면 즉시 끝낸다.
ex_verify_user_can_read_dir "$SERVICE_USER" "$TEXTFILE_DIR"

ex_firewall_hint "$PORT" "$LISTEN_ADDRESS" "$ALLOW_FROM"

cat <<NEXT

[$EX_COMPONENT] 다음 단계를 직접 확인하십시오.
  1) systemctl status $UNIT_NAME
  2) curl -s http://${LISTEN_ADDRESS}:${PORT}/metrics | head
  3) VM2 에서 curl -s http://${LISTEN_ADDRESS}:${PORT}/metrics | head 로 원격 접근을 확인한다.
  4) VM3 처럼 백업이 도는 호스트라면 ls -l $TEXTFILE_DIR 로 .prom 파일이 쌓이는지 확인한다.
  5) Prometheus 의 Status > Targets 에서 해당 target 이 up 으로 바뀌었는지 확인한다.
NEXT
