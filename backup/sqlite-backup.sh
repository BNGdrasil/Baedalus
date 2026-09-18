#!/usr/bin/env bash
#
# SQLite 온라인 백업. Overlock 과 Grafana 의 DB 파일을 서비스 중지 없이 복사한다.
#
#   ./sqlite-backup.sh --name overlock --source /var/lib/overlock/overlock.sqlite
#   ./sqlite-backup.sh --name grafana  --source /var/lib/docker/volumes/<볼륨>/_data/grafana.db
#
# 파일을 그대로 cp 하면 WAL 과 어긋난 사본이 나올 수 있으므로 SQLite 의 온라인 백업
# API 를 사용한다. python3 가 있으면 sqlite3 모듈의 backup() 을, 없으면 sqlite3 CLI 의
# .backup 명령을 쓴다. 복사한 뒤에는 PRAGMA integrity_check 로 무결성을 확인한다.

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

NAME=""
SOURCE=""

usage() {
    echo "usage: sqlite-backup.sh --name <라벨> --source <SQLite 파일 경로>" >&2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --name)   NAME="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "알 수 없는 인자입니다: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$NAME" ]   || { usage; exit 2; }
[ -n "$SOURCE" ] || { usage; exit 2; }

BK_COMPONENT="sqlite-$NAME"
bk_load_env

SQLITE_BACKUP_DIR="${SQLITE_BACKUP_DIR:-$BACKUP_ROOT/sqlite}"
SQLITE_MIN_FREE_BYTES="${SQLITE_MIN_FREE_BYTES:-268435456}"
PYTHON_CMD="${PYTHON_CMD:-python3}"
SQLITE3_CMD="${SQLITE3_CMD:-sqlite3}"

STATE_LAST_RUN="$STATE_DIR/sqlite-$NAME-last-run.json"
STATE_LAST_SUCCESS="$STATE_DIR/sqlite-$NAME-last-success.json"

BK_ERROR=""
RUN_ID="$(bk_run_id)"
STARTED_AT="$(bk_now_iso)"
DEST=""
TARGET_FILE=""
TOTAL_BYTES=0
SHA_VALUE=""
INTEGRITY="unknown"

write_state() {
    local status="$1" finished_at="$2"
    local error_json="null"
    [ -z "$BK_ERROR" ] || error_json="\"$(bk_json_escape "$BK_ERROR")\""
    {
        echo "{"
        printf '  %s,\n' "$(bk_json_kv component "$BK_COMPONENT")"
        printf '  %s,\n' "$(bk_json_kv run_id "$RUN_ID")"
        printf '  %s,\n' "$(bk_json_kv status "$status")"
        printf '  %s,\n' "$(bk_json_kv source "$SOURCE")"
        printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
        printf '  %s,\n' "$(bk_json_kv finished_at "$finished_at")"
        printf '  %s,\n' "$(bk_json_kv_raw finished_epoch "$(bk_now_epoch)")"
        printf '  %s,\n' "$(bk_json_kv file "$TARGET_FILE")"
        printf '  %s,\n' "$(bk_json_kv_raw total_bytes "$TOTAL_BYTES")"
        printf '  %s,\n' "$(bk_json_kv sha256 "$SHA_VALUE")"
        printf '  %s,\n' "$(bk_json_kv integrity_check "$INTEGRITY")"
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
        [ -n "$BK_ERROR" ] || BK_ERROR="sqlite-backup.sh 가 exit code $rc 로 종료했습니다."
        write_state "failed" "$finished_at"
        bk_write_metrics "$BK_COMPONENT" 1 "$(bk_last_success_field "$STATE_LAST_SUCCESS" finished_epoch || true)"
    fi
    bk_release_lock
    return "$rc"
}
trap on_exit EXIT

bk_acquire_lock "sqlite-$NAME" || exit 1

[ -r "$SOURCE" ] || bk_fail "원본 SQLite 파일을 읽을 수 없습니다: $SOURCE"

mkdir -p "$SQLITE_BACKUP_DIR"
free_bytes="$(bk_free_bytes "$SQLITE_BACKUP_DIR")"
case "$free_bytes" in
    ''|*[!0-9]*) bk_fail "대상 파티션의 여유 공간을 확인하지 못했습니다: $SQLITE_BACKUP_DIR" ;;
esac
source_bytes="$(bk_file_bytes "$SOURCE")"
required_bytes=$((source_bytes * 2))
[ "$required_bytes" -ge "$SQLITE_MIN_FREE_BYTES" ] || required_bytes="$SQLITE_MIN_FREE_BYTES"
[ "$free_bytes" -ge "$required_bytes" ] || \
    bk_fail "디스크 여유가 부족합니다. 필요 ${required_bytes} bytes, 현재 ${free_bytes} bytes"

DEST="$SQLITE_BACKUP_DIR/$NAME/$RUN_ID"
[ ! -e "$DEST" ] || bk_fail "같은 run id 의 디렉터리가 이미 존재합니다: $DEST"
mkdir -p "$DEST"
TARGET_FILE="$NAME.sqlite"
target="$DEST/$TARGET_FILE"
partial="$target.partial"

bk_log "SQLite 온라인 백업 시작: $SOURCE"
if command -v "$PYTHON_CMD" >/dev/null 2>&1; then
    # python3 의 sqlite3.Connection.backup() 은 잠금을 유지한 채 일관된 사본을 만든다.
    "$PYTHON_CMD" - "$SOURCE" "$partial" <<'PYEOF' || bk_fail "python sqlite3 backup API 실패"
import sqlite3
import sys

source_path, dest_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect("file:%s?mode=ro" % source_path, uri=True)
dst = sqlite3.connect(dest_path)
try:
    with dst:
        src.backup(dst)
finally:
    dst.close()
    src.close()
PYEOF
elif command -v "$SQLITE3_CMD" >/dev/null 2>&1; then
    "$SQLITE3_CMD" "file:$SOURCE?mode=ro" ".backup '$partial'" || bk_fail "sqlite3 .backup 실패"
else
    bk_fail "python3 와 sqlite3 중 어느 것도 찾지 못했습니다."
fi

[ -s "$partial" ] || bk_fail "백업 파일이 비어 있습니다."

# --- 무결성 검사 ---------------------------------------------------------------
if command -v "$SQLITE3_CMD" >/dev/null 2>&1; then
    INTEGRITY="$("$SQLITE3_CMD" "$partial" 'PRAGMA integrity_check;' | head -n1)"
elif command -v "$PYTHON_CMD" >/dev/null 2>&1; then
    INTEGRITY="$("$PYTHON_CMD" -c 'import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute("PRAGMA integrity_check").fetchone()[0])' "$partial")"
else
    bk_fail "무결성 검사 도구를 찾지 못했습니다."
fi
[ "$INTEGRITY" = "ok" ] || bk_fail "PRAGMA integrity_check 결과가 ok 가 아닙니다: $INTEGRITY"

mv "$partial" "$target"
bk_sha256_file "$target" > "$target.sha256"
TOTAL_BYTES="$(bk_file_bytes "$target")"
SHA_VALUE="$(awk '{print $1}' "$target.sha256")"
bk_log "SQLite 백업 성공: $target (${TOTAL_BYTES} bytes, integrity_check=$INTEGRITY)"
