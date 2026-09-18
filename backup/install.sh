#!/usr/bin/env bash
#
# VM3 설치 스크립트. 몇 번을 실행해도 같은 결과가 되도록 만들었다.
#
#   sudo ./install.sh                 파일 복사, 환경 파일 준비, timer 활성화
#   sudo ./install.sh --run-now       설치한 뒤 최초 백업을 즉시 실행
#   sudo ./install.sh --no-enable     파일만 설치하고 timer 는 건드리지 않는다
#   sudo ./install.sh --uninstall     timer 를 중지하고 유닛을 제거(백업 데이터는 유지)
#
# 이미 있는 /etc/bngdrasil-backup/env 는 덮어쓰지 않는다. 백업 데이터도 지우지 않는다.

set -euo pipefail
umask 022

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/bngdrasil-backup}"
CONFIG_DIR="${CONFIG_DIR:-/etc/bngdrasil-backup}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
DATA_DIR="${DATA_DIR:-/var/backups/bngdrasil}"

RUN_NOW=0
DO_ENABLE=1
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --run-now)   RUN_NOW=1 ;;
        --no-enable) DO_ENABLE=0 ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "알 수 없는 인자입니다: $arg" >&2; exit 2 ;;
    esac
done

log() { printf '[install] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "root 권한으로 실행해야 합니다." >&2; exit 1; }

UNITS="bngdrasil-backup.service bngdrasil-backup.timer
bngdrasil-backup-ship.service bngdrasil-backup-ship.timer
bngdrasil-backup-verify.service bngdrasil-backup-verify.timer
bngdrasil-backup-notify@.service"

if [ "$UNINSTALL" -eq 1 ]; then
    log "timer 를 중지하고 유닛을 제거합니다. 백업 데이터와 환경 파일은 그대로 둡니다."
    for t in bngdrasil-backup.timer bngdrasil-backup-ship.timer bngdrasil-backup-verify.timer; do
        systemctl disable --now "$t" 2>/dev/null || true
    done
    for u in $UNITS; do
        rm -f "$SYSTEMD_DIR/$u"
    done
    systemctl daemon-reload
    log "제거를 마쳤습니다. 데이터는 $DATA_DIR 에 남아 있습니다."
    exit 0
fi

# --- 1. 디렉터리 -------------------------------------------------------------
install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/lib" "$INSTALL_DIR/systemd"
install -d -m 0700 "$CONFIG_DIR" "$CONFIG_DIR/ssh"
install -d -m 0700 "$DATA_DIR" "$DATA_DIR/state" "$DATA_DIR/locks"

# --- 2. 스크립트 복사 ---------------------------------------------------------
for f in pg-backup.sh redis-backup.sh sqlite-backup.sh retention.sh ship.sh \
         notify.sh run.sh verify-restore.sh install.sh; do
    install -m 0750 "$SRC_DIR/$f" "$INSTALL_DIR/$f"
done
install -m 0640 "$SRC_DIR/lib/common.sh" "$INSTALL_DIR/lib/common.sh"
install -m 0644 "$SRC_DIR/env.example" "$INSTALL_DIR/env.example"
[ ! -f "$SRC_DIR/README.md" ] || install -m 0644 "$SRC_DIR/README.md" "$INSTALL_DIR/README.md"
log "스크립트를 $INSTALL_DIR 에 설치했습니다."

# --- 3. 환경 파일 -------------------------------------------------------------
if [ -f "$CONFIG_DIR/env" ]; then
    log "$CONFIG_DIR/env 가 이미 있으므로 덮어쓰지 않습니다."
else
    install -m 0600 "$SRC_DIR/env.example" "$CONFIG_DIR/env"
    log "$CONFIG_DIR/env 를 템플릿에서 새로 만들었습니다. 값을 채운 뒤 백업을 실행하십시오."
fi
chmod 0600 "$CONFIG_DIR/env"
chown root:root "$CONFIG_DIR/env"

# --- 3-1. 전송용 SSH 설정 ------------------------------------------------------
# systemd 유닛이 ProtectHome=yes 로 실행되므로 root 홈의 ~/.ssh 는 쓰지 않는다.
# 전송에 필요한 설정과 개인 키는 이 디렉터리에 두고 ship.sh 가 -F 와 -i 로 명시한다.
if [ -f "$CONFIG_DIR/ssh/config" ]; then
    log "$CONFIG_DIR/ssh/config 가 이미 있으므로 덮어쓰지 않습니다."
else
    cat > "$CONFIG_DIR/ssh/config" <<'SSHCFG'
# BNGdrasil 백업 전송용 SSH 설정.
# ship.sh 가 ssh -F 로 이 파일을 명시하므로 root 홈의 ~/.ssh 는 사용하지 않는다.
# 아래 값은 예시이며 실제 사용자 이름과 주소로 바꾸어야 한다.
#Host bngdrasil-vm2
#    HostName 10.0.2.x
#    User ubuntu
#    IdentityFile /etc/bngdrasil-backup/ssh/id_ed25519
#
#Host bngdrasil-vm4
#    HostName 10.1.2.111
#    User ubuntu
#    IdentityFile /etc/bngdrasil-backup/ssh/id_ed25519
#    ProxyJump bngdrasil-vm2
SSHCFG
    log "$CONFIG_DIR/ssh/config 템플릿을 만들었습니다. 실제 호스트 정보를 채우십시오."
fi
chmod 0600 "$CONFIG_DIR/ssh/config"
[ ! -f "$CONFIG_DIR/ssh/id_ed25519" ] || chmod 0600 "$CONFIG_DIR/ssh/id_ed25519"
[ -f "$CONFIG_DIR/ssh/known_hosts" ] || : > "$CONFIG_DIR/ssh/known_hosts"
chmod 0600 "$CONFIG_DIR/ssh/known_hosts"
chown -R root:root "$CONFIG_DIR/ssh"

# --- 4. systemd 유닛 ----------------------------------------------------------
for u in $UNITS; do
    install -m 0644 "$SRC_DIR/systemd/$u" "$SYSTEMD_DIR/$u"
done
systemctl daemon-reload
log "systemd 유닛을 설치하고 daemon-reload 를 실행했습니다."

if [ "$DO_ENABLE" -eq 1 ]; then
    systemctl enable --now bngdrasil-backup.timer
    systemctl enable --now bngdrasil-backup-verify.timer
    if grep -Eq '^[[:space:]]*SHIP_ENCRYPTION=' "$CONFIG_DIR/env"; then
        systemctl enable --now bngdrasil-backup-ship.timer
        log "전송 timer 를 활성화했습니다."
    else
        log "SHIP_ENCRYPTION 설정이 없어 전송 timer 는 활성화하지 않았습니다. 키를 준비한 뒤 systemctl enable --now bngdrasil-backup-ship.timer 를 실행하십시오."
        if ! grep -Eq '^[[:space:]]*SHIP_ENABLED=' "$CONFIG_DIR/env"; then
            log "경고: run.sh 는 기본적으로 백업 직후에 전송을 수행합니다. 전송을 아직 쓰지 않는다면 $CONFIG_DIR/env 에 SHIP_ENABLED=false 를 지정하십시오. 그렇게 하지 않으면 매 실행이 전송 단계에서 실패합니다."
        fi
    fi
    log "백업 timer 와 복원 훈련 timer 를 활성화했습니다."
else
    log "--no-enable 이므로 timer 를 건드리지 않았습니다."
fi

# --- 5. 최초 실행과 검증 --------------------------------------------------------
if [ "$RUN_NOW" -eq 1 ]; then
    log "최초 백업을 실행합니다."
    "$INSTALL_DIR/run.sh"
    log "최초 백업이 끝났습니다. 상태 파일을 확인합니다."
    cat "$DATA_DIR/state/last-run.json"
    log "격리 복원 훈련을 실행합니다."
    "$INSTALL_DIR/verify-restore.sh"
else
    cat <<'NEXT'
[install] 다음 단계를 직접 실행하십시오.
  1) /etc/bngdrasil-backup/env 의 값을 채운다.
  2) /opt/bngdrasil-backup/run.sh 를 한 번 실행하여 최초 백업을 만든다.
  3) cat /var/backups/bngdrasil/state/last-run.json 으로 status 가 success 인지 확인한다.
  4) /opt/bngdrasil-backup/verify-restore.sh 로 격리 복원이 성공하는지 확인한다.
  5) systemctl list-timers 'bngdrasil-*' 로 다음 실행 시각을 확인한다.
NEXT
fi
