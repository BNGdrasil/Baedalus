#!/usr/bin/env bash
#
# 백업 결과 알림 훅.
#
#   ./notify.sh <success|failure|warning> <구성 요소> <메시지>
#
# webhook URL 은 /etc/bngdrasil-backup/env 에서만 읽으며 이 스크립트에 값을 적지 않는다.
# URL 이 없거나 전송에 실패하면 syslog(journal)에 기록하여 기록 자체는 남긴다.

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

# BK_COMPONENT 는 lib/common.sh 의 로그 함수가 읽는다.
# shellcheck disable=SC2034
BK_COMPONENT="notify"
bk_load_env

STATUS="${1:-unknown}"
COMPONENT="${2:-backup}"
MESSAGE="${3:-}"

NOTIFY_WEBHOOK_KIND="${NOTIFY_WEBHOOK_KIND:-discord}"
NOTIFY_HOSTNAME="${NOTIFY_HOSTNAME:-$(hostname 2>/dev/null || echo unknown-host)}"
NOTIFY_TIMEOUT="${NOTIFY_TIMEOUT:-10}"

case "$STATUS" in
    success) prefix="[성공]" ; priority="info" ;;
    warning) prefix="[경고]" ; priority="warning" ;;
    *)       prefix="[실패]" ; priority="err" ;;
esac

TEXT="$prefix BNGdrasil 백업 / ${NOTIFY_HOSTNAME} / ${COMPONENT} / $(bk_now_iso)"
[ -z "$MESSAGE" ] || TEXT="$TEXT
$MESSAGE"

log_local() {
    if command -v logger >/dev/null 2>&1; then
        printf '%s\n' "$TEXT" | logger -t bngdrasil-backup -p "user.$priority"
    else
        printf '%s\n' "$TEXT" >&2
    fi
}

if [ -z "${NOTIFY_WEBHOOK_URL:-}" ] || ! command -v curl >/dev/null 2>&1; then
    log_local
    exit 0
fi

case "$NOTIFY_WEBHOOK_KIND" in
    slack) payload="{\"text\": \"$(bk_json_escape "$TEXT")\"}" ;;
    *)     payload="{\"content\": \"$(bk_json_escape "$TEXT")\"}" ;;
esac

if curl -sS -f -m "$NOTIFY_TIMEOUT" -H 'Content-Type: application/json' \
        -X POST --data "$payload" "$NOTIFY_WEBHOOK_URL" > /dev/null; then
    exit 0
fi

bk_warn "webhook 전송에 실패하여 syslog 에만 기록합니다."
log_local
exit 1
