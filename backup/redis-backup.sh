#!/usr/bin/env bash
#
# Redis 스냅샷 백업. VM3 의 vm3-redis 와 VM2 의 vm2-redis 를 같은 스크립트로 처리한다.
#
#   ./redis-backup.sh --name vm3 --mode container --target vm3-redis
#   ./redis-backup.sh --name vm2 --mode host --target 127.0.0.1 --port 6379
#
# container 모드는 docker exec 으로 컨테이너 안에서 redis-cli 를 실행하고,
# host 모드는 호스트에 설치된 redis-cli 로 접속한다.
# 두 경우 모두 redis-cli --rdb 로 복제 스냅샷을 받고 redis-check-rdb 로 검증한다.
# --rdb 를 쓸 수 없는 구형 서버에서는 --via-bgsave 로 BGSAVE 후 RDB 파일을 복사한다.

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

NAME=""
MODE="container"
TARGET=""
PORT="6379"
VIA_BGSAVE=0
REMOTE_RDB_PATH="/data/dump.rdb"

usage() {
    cat <<'USAGE'
usage: redis-backup.sh --name <라벨> --mode <container|host> --target <컨테이너명|호스트> [옵션]
  --port <포트>          host 모드에서 사용할 포트. 기본값은 6379이다.
  --via-bgsave           redis-cli --rdb 대신 BGSAVE 후 RDB 파일을 복사한다.
  --rdb-path <경로>      --via-bgsave 에서 원본 RDB 경로. 기본값은 /data/dump.rdb 이다.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)     NAME="$2"; shift 2 ;;
        --mode)     MODE="$2"; shift 2 ;;
        --target)   TARGET="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --rdb-path) REMOTE_RDB_PATH="$2"; shift 2 ;;
        --via-bgsave) VIA_BGSAVE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "알 수 없는 인자입니다: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$NAME" ]   || { echo "--name 이 필요합니다." >&2; exit 2; }
[ -n "$TARGET" ] || { echo "--target 이 필요합니다." >&2; exit 2; }

BK_COMPONENT="redis-$NAME"
bk_load_env

REDIS_BACKUP_DIR="${REDIS_BACKUP_DIR:-$BACKUP_ROOT/redis}"
REDIS_MIN_FREE_BYTES="${REDIS_MIN_FREE_BYTES:-536870912}"
DOCKER_CMD="${DOCKER_CMD:-docker}"

STATE_LAST_RUN="$STATE_DIR/redis-$NAME-last-run.json"
STATE_LAST_SUCCESS="$STATE_DIR/redis-$NAME-last-success.json"

BK_ERROR=""
RUN_ID="$(bk_run_id)"
STARTED_AT="$(bk_now_iso)"
DEST=""
TARGET_FILE=""
TOTAL_BYTES=0
SHA_VALUE=""

write_state() {
    local status="$1" finished_at="$2"
    local error_json="null"
    [ -z "$BK_ERROR" ] || error_json="\"$(bk_json_escape "$BK_ERROR")\""
    {
        echo "{"
        printf '  %s,\n' "$(bk_json_kv component "$BK_COMPONENT")"
        printf '  %s,\n' "$(bk_json_kv run_id "$RUN_ID")"
        printf '  %s,\n' "$(bk_json_kv status "$status")"
        printf '  %s,\n' "$(bk_json_kv mode "$MODE")"
        printf '  %s,\n' "$(bk_json_kv target "$TARGET")"
        printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
        printf '  %s,\n' "$(bk_json_kv finished_at "$finished_at")"
        printf '  %s,\n' "$(bk_json_kv_raw finished_epoch "$(bk_now_epoch)")"
        printf '  %s,\n' "$(bk_json_kv file "$TARGET_FILE")"
        printf '  %s,\n' "$(bk_json_kv_raw total_bytes "$TOTAL_BYTES")"
        printf '  %s,\n' "$(bk_json_kv sha256 "$SHA_VALUE")"
        printf '  %s\n'  "$(bk_json_kv_raw error "$error_json")"
        echo "}"
    } | bk_write_file "$STATE_LAST_RUN"
    [ "$status" != "success" ] || cp -p "$STATE_LAST_RUN" "$STATE_LAST_SUCCESS"
}

on_exit() {
    local rc=$?
    local finished_at
    finished_at="$(bk_now_iso)"
    [ -z "$DEST" ] || find "$DEST" -maxdepth 1 -name '*.partial' -type f -exec rm -f {} + 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
        [ -z "$DEST" ] || : > "$DEST/SUCCESS"
        write_state "success" "$finished_at"
        bk_write_metrics "$BK_COMPONENT" 0 "$(bk_now_epoch)"
    else
        [ -z "$DEST" ] || : > "$DEST/FAILED"
        [ -n "$BK_ERROR" ] || BK_ERROR="redis-backup.sh 가 exit code $rc 로 종료했습니다."
        write_state "failed" "$finished_at"
        bk_write_metrics "$BK_COMPONENT" 1 "$(bk_last_success_field "$STATE_LAST_SUCCESS" finished_epoch || true)"
    fi
    bk_release_lock
    return "$rc"
}
trap on_exit EXIT

bk_acquire_lock "redis-$NAME" || exit 1

mkdir -p "$REDIS_BACKUP_DIR"
free_bytes="$(bk_free_bytes "$REDIS_BACKUP_DIR")"
case "$free_bytes" in
    ''|*[!0-9]*) bk_fail "대상 파티션의 여유 공간을 확인하지 못했습니다: $REDIS_BACKUP_DIR" ;;
esac
required_bytes="$REDIS_MIN_FREE_BYTES"
last_bytes="$(bk_last_success_field "$STATE_LAST_SUCCESS" total_bytes || true)"
case "$last_bytes" in
    ''|*[!0-9]*) : ;;
    *) [ $((last_bytes * 2)) -le "$required_bytes" ] || required_bytes=$((last_bytes * 2)) ;;
esac
[ "$free_bytes" -ge "$required_bytes" ] || \
    bk_fail "디스크 여유가 부족합니다. 필요 ${required_bytes} bytes, 현재 ${free_bytes} bytes"

DEST="$REDIS_BACKUP_DIR/$NAME/$RUN_ID"
[ ! -e "$DEST" ] || bk_fail "같은 run id 의 디렉터리가 이미 존재합니다: $DEST"
mkdir -p "$DEST"
TARGET_FILE="redis-$NAME.rdb"
target="$DEST/$TARGET_FILE"
partial="$target.partial"

# 비밀번호는 명령 인자로 넘기지 않고 redis-cli 가 읽는 REDISCLI_AUTH 로만 전달한다.
REDIS_AUTH_VALUE=""
if [ -n "${REDIS_PASSWORD_FILE:-}" ] && [ -r "${REDIS_PASSWORD_FILE}" ]; then
    REDIS_AUTH_VALUE="$(head -n1 "$REDIS_PASSWORD_FILE")"
fi

run_redis_cli() {
    # 컨테이너/호스트 차이를 이 함수 하나로 흡수한다. 출력은 그대로 전달한다.
    if [ "$MODE" = "container" ]; then
        if [ -n "$REDIS_AUTH_VALUE" ]; then
            "$DOCKER_CMD" exec -e REDISCLI_AUTH="$REDIS_AUTH_VALUE" -i "$TARGET" redis-cli "$@"
        else
            "$DOCKER_CMD" exec -i "$TARGET" redis-cli "$@"
        fi
    else
        REDISCLI_AUTH="$REDIS_AUTH_VALUE" redis-cli -h "$TARGET" -p "$PORT" "$@"
    fi
}

bk_log "Redis 스냅샷 시작: mode=$MODE target=$TARGET"
if ! run_redis_cli PING | grep -q PONG; then
    bk_fail "Redis 에 연결하지 못했습니다: $TARGET"
fi

if [ "$VIA_BGSAVE" -eq 1 ]; then
    # BGSAVE 경로: 저장 시각이 갱신될 때까지 기다린 뒤 RDB 파일을 복사한다.
    before="$(run_redis_cli LASTSAVE | tr -d '\r')"
    run_redis_cli BGSAVE > /dev/null
    waited=0
    while [ "$waited" -lt "${REDIS_BGSAVE_TIMEOUT:-120}" ]; do
        sleep 2
        waited=$((waited + 2))
        now="$(run_redis_cli LASTSAVE | tr -d '\r')"
        [ "$now" = "$before" ] || break
    done
    [ "${now:-$before}" != "$before" ] || bk_fail "BGSAVE 가 제한 시간 안에 끝나지 않았습니다."
    if [ "$MODE" = "container" ]; then
        "$DOCKER_CMD" cp "$TARGET:$REMOTE_RDB_PATH" "$partial" || bk_fail "RDB 파일 복사 실패"
    else
        cp "$REMOTE_RDB_PATH" "$partial" || bk_fail "RDB 파일 복사 실패"
    fi
else
    if [ "$MODE" = "container" ]; then
        # 컨테이너 안에서 임시 파일로 받은 뒤 docker cp 로 가져오고 원본을 지운다.
        tmp_in_container="/tmp/bngdrasil-backup-$RUN_ID.rdb"
        if [ -n "$REDIS_AUTH_VALUE" ]; then
            "$DOCKER_CMD" exec -e REDISCLI_AUTH="$REDIS_AUTH_VALUE" "$TARGET" \
                redis-cli --rdb "$tmp_in_container" || bk_fail "redis-cli --rdb 실패"
        else
            "$DOCKER_CMD" exec "$TARGET" redis-cli --rdb "$tmp_in_container" || bk_fail "redis-cli --rdb 실패"
        fi
        "$DOCKER_CMD" cp "$TARGET:$tmp_in_container" "$partial" || bk_fail "스냅샷 복사 실패"
        "$DOCKER_CMD" exec "$TARGET" rm -f "$tmp_in_container" || bk_warn "컨테이너 임시 파일을 지우지 못했습니다."
    else
        REDISCLI_AUTH="$REDIS_AUTH_VALUE" redis-cli -h "$TARGET" -p "$PORT" --rdb "$partial" \
            || bk_fail "redis-cli --rdb 실패"
    fi
fi

[ -s "$partial" ] || bk_fail "스냅샷 파일이 비어 있습니다."

# --- 검증 --------------------------------------------------------------------
check_ok=0
if command -v redis-check-rdb >/dev/null 2>&1; then
    redis-check-rdb "$partial" > "$DEST/redis-check-rdb.log" 2>&1 && check_ok=1
elif [ "$MODE" = "container" ]; then
    "$DOCKER_CMD" cp "$partial" "$TARGET:/tmp/verify-$RUN_ID.rdb" >/dev/null 2>&1 || true
    if "$DOCKER_CMD" exec "$TARGET" redis-check-rdb "/tmp/verify-$RUN_ID.rdb" \
            > "$DEST/redis-check-rdb.log" 2>&1; then
        check_ok=1
    fi
    "$DOCKER_CMD" exec "$TARGET" rm -f "/tmp/verify-$RUN_ID.rdb" >/dev/null 2>&1 || true
fi
[ "$check_ok" -eq 1 ] || bk_fail "redis-check-rdb 검증에 실패했거나 검증 도구를 찾지 못했습니다."

mv "$partial" "$target"
bk_sha256_file "$target" > "$target.sha256"
TOTAL_BYTES="$(bk_file_bytes "$target")"
SHA_VALUE="$(awk '{print $1}' "$target.sha256")"
bk_log "Redis 백업 성공: $target (${TOTAL_BYTES} bytes)"
