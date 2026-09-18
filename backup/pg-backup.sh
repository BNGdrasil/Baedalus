#!/usr/bin/env bash
#
# VM3 호스트 PostgreSQL 14 논리 백업.
# 04-runbook.md 4장의 검증된 명령 패턴을 그대로 따른다.
#   1) pg_dump --format=custom 결과를 .partial 에 쓴다.
#   2) 비어 있지 않은지 확인하고 pg_restore --list 로 archive 목록을 읽는다.
#   3) 통과한 파일만 최종 이름으로 rename 하고 sha256 을 남긴다.
#   4) 역할은 pg_dumpall --globals-only --no-role-passwords 로 따로 보존한다.
#
# 실패하면 non-zero 로 끝나고 .partial 임시 파일만 지운다.
# 이전에 성공한 백업 디렉터리는 어떤 경우에도 이 스크립트가 삭제하지 않는다.

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

BK_COMPONENT="postgresql"
bk_load_env

PG_DATABASES="${PG_DATABASES:-bngdrasil phishing_data postgres}"
PG_DUMP_CMD="${PG_DUMP_CMD:-sudo -n -u postgres pg_dump}"
PG_DUMPALL_CMD="${PG_DUMPALL_CMD:-sudo -n -u postgres pg_dumpall}"
PG_RESTORE_CMD="${PG_RESTORE_CMD:-pg_restore}"
PG_LOCK_WAIT_MS="${PG_LOCK_WAIT_MS:-15000}"
PG_MIN_FREE_BYTES="${PG_MIN_FREE_BYTES:-1073741824}"
PG_BACKUP_DIR="${PG_BACKUP_DIR:-$BACKUP_ROOT/postgresql}"

STATE_LAST_RUN="$STATE_DIR/postgresql-last-run.json"
STATE_LAST_SUCCESS="$STATE_DIR/postgresql-last-success.json"

BK_ERROR=""
RUN_ID="$(bk_run_id)"
STARTED_AT="$(bk_now_iso)"
DEST=""
DB_ENTRIES=""
SIZE_ENTRIES=""
SUM_ENTRIES=""
TOTAL_BYTES=0

json_append() {
    # json_append <varname> <fragment>
    # frag 는 아래 eval 안에서 사용한다.
    # shellcheck disable=SC2034
    local name="$1" frag="$2" cur
    eval "cur=\${$name}"
    if [ -n "$cur" ]; then
        eval "$name=\"\$cur, \$frag\""
    else
        eval "$name=\"\$frag\""
    fi
}

write_state() {
    local status="$1" finished_at="$2"
    local error_json="null"
    [ -z "$BK_ERROR" ] || error_json="\"$(bk_json_escape "$BK_ERROR")\""
    {
        echo "{"
        printf '  %s,\n' "$(bk_json_kv component "$BK_COMPONENT")"
        printf '  %s,\n' "$(bk_json_kv run_id "$RUN_ID")"
        printf '  %s,\n' "$(bk_json_kv status "$status")"
        printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
        printf '  %s,\n' "$(bk_json_kv finished_at "$finished_at")"
        printf '  %s,\n' "$(bk_json_kv_raw finished_epoch "$(bk_now_epoch)")"
        printf '  %s,\n' "$(bk_json_kv directory "$DEST")"
        printf '  %s,\n' "$(bk_json_kv_raw total_bytes "$TOTAL_BYTES")"
        printf '  %s,\n' "$(bk_json_kv_raw databases "[${DB_ENTRIES}]")"
        printf '  %s,\n' "$(bk_json_kv_raw sizes "{${SIZE_ENTRIES}}")"
        printf '  %s,\n' "$(bk_json_kv_raw checksums "{${SUM_ENTRIES}}")"
        printf '  %s\n' "$(bk_json_kv_raw error "$error_json")"
        echo "}"
    } | bk_write_file "$STATE_LAST_RUN"
    if [ "$status" = "success" ]; then
        cp -p "$STATE_LAST_RUN" "$STATE_LAST_SUCCESS"
    fi
}

on_exit() {
    local rc=$?
    local finished_at
    finished_at="$(bk_now_iso)"
    if [ -n "$DEST" ] && [ -d "$DEST" ]; then
        find "$DEST" -maxdepth 1 -name '*.partial' -type f -exec rm -f {} + 2>/dev/null || true
    fi
    if [ "$rc" -eq 0 ]; then
        [ -z "$DEST" ] || : > "$DEST/SUCCESS"
        write_state "success" "$finished_at"
        bk_write_metrics "$BK_COMPONENT" 0 "$(bk_now_epoch)"
    else
        [ -z "$DEST" ] || : > "$DEST/FAILED"
        [ -n "$BK_ERROR" ] || BK_ERROR="pg-backup.sh 가 exit code $rc 로 종료했습니다."
        write_state "failed" "$finished_at"
        local last_success=""
        last_success="$(bk_last_success_field "$STATE_LAST_SUCCESS" finished_epoch || true)"
        bk_write_metrics "$BK_COMPONENT" 1 "$last_success"
    fi
    bk_release_lock
    return "$rc"
}
trap on_exit EXIT

bk_acquire_lock "postgresql" || exit 1

read -r -a PG_DUMP_ARGV    <<< "$PG_DUMP_CMD"
read -r -a PG_DUMPALL_ARGV <<< "$PG_DUMPALL_CMD"
read -r -a PG_RESTORE_ARGV <<< "$PG_RESTORE_CMD"

mkdir -p "$PG_BACKUP_DIR"

# --- 디스크 여유 확인 ---------------------------------------------------------
# 마지막 성공 백업 크기의 2배를 요구한다. 성공 이력이 없으면 PG_MIN_FREE_BYTES 를 쓴다.
required_bytes="$PG_MIN_FREE_BYTES"
last_bytes="$(bk_last_success_field "$STATE_LAST_SUCCESS" total_bytes || true)"
case "$last_bytes" in
    ''|*[!0-9]*) : ;;
    *) required_bytes=$((last_bytes * 2)) ;;
esac
free_bytes="$(bk_free_bytes "$PG_BACKUP_DIR")"
case "$free_bytes" in
    ''|*[!0-9]*) bk_fail "대상 파티션의 여유 공간을 확인하지 못했습니다: $PG_BACKUP_DIR" ;;
esac
if [ "$free_bytes" -lt "$required_bytes" ]; then
    bk_fail "디스크 여유가 부족합니다. 필요 ${required_bytes} bytes, 현재 ${free_bytes} bytes ($PG_BACKUP_DIR)"
fi
bk_log "디스크 여유 ${free_bytes} bytes, 요구 ${required_bytes} bytes"

DEST="$PG_BACKUP_DIR/$RUN_ID"
[ ! -e "$DEST" ] || bk_fail "같은 run id 의 디렉터리가 이미 존재합니다: $DEST"
mkdir -p "$DEST"

# --- 데이터베이스별 dump -----------------------------------------------------
for db in $PG_DATABASES; do
    target="$DEST/postgresql-$db.dump"
    partial="$target.partial"
    [ ! -e "$target" ]  || bk_fail "백업 파일이 이미 존재합니다: $target"
    [ ! -e "$partial" ] || bk_fail "임시 파일이 이미 존재합니다: $partial"

    bk_log "dump 시작: $db"
    if ! "${PG_DUMP_ARGV[@]}" --format=custom --lock-wait-timeout="$PG_LOCK_WAIT_MS" \
            --dbname="$db" > "$partial"; then
        bk_fail "pg_dump 실패: $db"
    fi
    [ -s "$partial" ] || bk_fail "dump 결과가 비어 있습니다: $db"
    if ! "${PG_RESTORE_ARGV[@]}" --list "$partial" > /dev/null; then
        bk_fail "pg_restore --list 검증 실패: $db"
    fi
    mv "$partial" "$target"
    bk_sha256_file "$target" > "$target.sha256"

    bytes="$(bk_file_bytes "$target")"
    sum="$(awk '{print $1}' "$target.sha256")"
    TOTAL_BYTES=$((TOTAL_BYTES + bytes))
    json_append DB_ENTRIES "{$(bk_json_kv name "$db"), $(bk_json_kv file "$(basename "$target")"), $(bk_json_kv_raw bytes "$bytes"), $(bk_json_kv sha256 "$sum"), $(bk_json_kv status ok)}"
    json_append SIZE_ENTRIES "$(bk_json_kv_raw "$db" "$bytes")"
    json_append SUM_ENTRIES "$(bk_json_kv "$db" "$sum")"
    bk_log "dump 완료: $db (${bytes} bytes)"
done

# --- 전역 역할 -----------------------------------------------------------------
globals="$DEST/globals-no-role-passwords.sql"
if ! "${PG_DUMPALL_ARGV[@]}" --globals-only --no-role-passwords > "$globals.partial"; then
    bk_fail "pg_dumpall --globals-only 실패"
fi
[ -s "$globals.partial" ] || bk_fail "전역 역할 dump 결과가 비어 있습니다."
mv "$globals.partial" "$globals"
bk_sha256_file "$globals" > "$globals.sha256"
globals_bytes="$(bk_file_bytes "$globals")"
TOTAL_BYTES=$((TOTAL_BYTES + globals_bytes))
json_append SIZE_ENTRIES "$(bk_json_kv_raw globals "$globals_bytes")"
json_append SUM_ENTRIES "$(bk_json_kv globals "$(awk '{print $1}' "$globals.sha256")")"
bk_log "전역 역할 dump 완료 (${globals_bytes} bytes). 복원할 때 비밀번호를 새로 설정해야 합니다."

# --- 디렉터리 manifest --------------------------------------------------------
{
    echo "{"
    printf '  %s,\n' "$(bk_json_kv run_id "$RUN_ID")"
    printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
    printf '  %s,\n' "$(bk_json_kv finished_at "$(bk_now_iso)")"
    printf '  %s,\n' "$(bk_json_kv_raw finished_epoch "$(bk_now_epoch)")"
    printf '  %s,\n' "$(bk_json_kv_raw total_bytes "$TOTAL_BYTES")"
    printf '  %s\n'  "$(bk_json_kv_raw databases "[${DB_ENTRIES}]")"
    echo "}"
} | bk_write_file "$DEST/manifest.json"

( cd "$DEST" && bk_sha256_file "manifest.json" > SHA256SUMS.manifest ) || true

bk_log "PostgreSQL 백업 성공: $DEST (${TOTAL_BYTES} bytes)"
