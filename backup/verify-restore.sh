#!/usr/bin/env bash
#
# 격리 복원 훈련. 최신 성공 백업을 일회용 PostgreSQL 에 복원하고 결과를 JSON 으로 남긴다.
#
#   ./verify-restore.sh                      최신 백업을 postgres:14 컨테이너에 복원
#   ./verify-restore.sh --pg-version 17      PG14 -> PG17 전환(I04) 사전 시험
#   ./verify-restore.sh --mode local         Docker 없이 initdb 로 임시 클러스터 사용
#   ./verify-restore.sh --dump-dir <경로>    특정 백업 디렉터리 지정
#
# 운영 DB 에는 접속하지 않는다. 컨테이너는 임시 이름과 임시 포트를 쓰고 종료할 때 지운다.
# 04-runbook.md 4장의 "격리 복원 훈련" 절차를 스크립트로 옮긴 것이다.

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

# BK_COMPONENT 는 lib/common.sh 의 로그 함수가 읽는다.
# shellcheck disable=SC2034
BK_COMPONENT="verify-restore"
bk_load_env

MODE="docker"
PG_VERSION="${VERIFY_PG_VERSION:-14}"
DUMP_DIR=""
PORT="${VERIFY_PORT:-55439}"
OUTPUT=""
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --mode)       MODE="$2"; shift 2 ;;
        --pg-version) PG_VERSION="$2"; shift 2 ;;
        --dump-dir)   DUMP_DIR="$2"; shift 2 ;;
        --port)       PORT="$2"; shift 2 ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --keep)       KEEP=1; shift ;;
        -h|--help)    sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "알 수 없는 인자입니다: $1" >&2; exit 2 ;;
    esac
done

DOCKER_CMD="${DOCKER_CMD:-docker}"
PG_BIN_DIR="${PG_BIN_DIR:-}"
RUN_ID="$(bk_run_id)"
STARTED_AT="$(bk_now_iso)"
OUTPUT="${OUTPUT:-$STATE_DIR/verify-restore-$RUN_ID.json}"

CONTAINER_NAME="bngdrasil-verify-$RUN_ID"
LOCAL_TMP=""
CONTAINER_STARTED=0
LOCAL_STARTED=0
RESULTS=""
FAILED_DBS=0
# 루프에 들어가기 전에 종료하더라도 결과가 success 로 남지 않도록 failed 에서 시작한다.
# 모든 데이터베이스가 passed 일 때에만 마지막에 success 로 바꾼다.
OVERALL="failed"
BK_ERROR=""

pgbin() { if [ -n "$PG_BIN_DIR" ]; then printf '%s/%s' "$PG_BIN_DIR" "$1"; else printf '%s' "$1"; fi; }

json_append() {
    local frag="$1"
    if [ -n "$RESULTS" ]; then RESULTS="$RESULTS, $frag"; else RESULTS="$frag"; fi
}

cleanup() {
    local rc=$?
    if [ "$KEEP" -eq 0 ]; then
        if [ "$CONTAINER_STARTED" -eq 1 ]; then
            "$DOCKER_CMD" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
        fi
        if [ "$LOCAL_STARTED" -eq 1 ]; then
            "$(pgbin pg_ctl)" -D "$LOCAL_TMP/data" -m fast -w stop >/dev/null 2>&1 || true
        fi
        [ -z "$LOCAL_TMP" ] || rm -rf "$LOCAL_TMP"
    else
        bk_log "--keep 옵션이 있으므로 임시 환경을 남겨 둡니다."
    fi
    write_output
    bk_release_lock
    return "$rc"
}

write_output() {
    local error_json="null"
    [ -z "$BK_ERROR" ] || error_json="\"$(bk_json_escape "$BK_ERROR")\""
    {
        echo "{"
        printf '  %s,\n' "$(bk_json_kv run_id "$RUN_ID")"
        printf '  %s,\n' "$(bk_json_kv status "$OVERALL")"
        printf '  %s,\n' "$(bk_json_kv mode "$MODE")"
        printf '  %s,\n' "$(bk_json_kv postgres_version "$PG_VERSION")"
        printf '  %s,\n' "$(bk_json_kv dump_dir "$DUMP_DIR")"
        printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
        printf '  %s,\n' "$(bk_json_kv finished_at "$(bk_now_iso)")"
        printf '  %s,\n' "$(bk_json_kv_raw databases "[${RESULTS}]")"
        printf '  %s\n'  "$(bk_json_kv_raw error "$error_json")"
        echo "}"
    } | bk_write_file "$OUTPUT"
    bk_log "복원 검증 결과: $OUTPUT"
}

trap cleanup EXIT
bk_acquire_lock "verify-restore" || exit 1

# --- 대상 백업 선택 ------------------------------------------------------------
if [ -z "$DUMP_DIR" ]; then
    DUMP_DIR="$(find "$BACKUP_ROOT/postgresql" -mindepth 1 -maxdepth 1 -type d \
        -exec test -e '{}/SUCCESS' ';' -print 2>/dev/null | sort -r | head -n1 || true)"
fi
[ -n "$DUMP_DIR" ] || bk_fail "복원할 성공 백업을 찾지 못했습니다."
[ -d "$DUMP_DIR" ] || bk_fail "백업 디렉터리가 없습니다: $DUMP_DIR"
bk_log "검증 대상: $DUMP_DIR"

# --- 일회용 PostgreSQL 준비 ----------------------------------------------------
if [ "$MODE" = "docker" ]; then
    command -v "$DOCKER_CMD" >/dev/null 2>&1 || bk_fail "docker 를 찾지 못했습니다."
    bk_log "일회용 컨테이너 시작: postgres:$PG_VERSION (포트 $PORT)"
    "$DOCKER_CMD" run -d --name "$CONTAINER_NAME" \
        -e POSTGRES_PASSWORD="verify-$RUN_ID" \
        -e POSTGRES_HOST_AUTH_METHOD=trust \
        -p "127.0.0.1:$PORT:5432" \
        "postgres:$PG_VERSION" >/dev/null || bk_fail "일회용 PostgreSQL 컨테이너를 시작하지 못했습니다."
    CONTAINER_STARTED=1
    ready=0
    for _ in $(seq 1 60); do
        if "$DOCKER_CMD" exec "$CONTAINER_NAME" pg_isready -U postgres >/dev/null 2>&1; then
            ready=1; break
        fi
        sleep 2
    done
    [ "$ready" -eq 1 ] || bk_fail "일회용 PostgreSQL 이 준비되지 않았습니다."
    # psql 과 createdb 에는 -i 를 주지 않는다. -i 를 주면 docker exec 가 호출한 쪽의
    # 표준 입력을 함께 읽어 버려서 반복문에 남은 입력이 사라진다.
    run_psql()      { "$DOCKER_CMD" exec "$CONTAINER_NAME" psql -X -U postgres "$@" < /dev/null; }
    run_createdb()  { "$DOCKER_CMD" exec "$CONTAINER_NAME" createdb -U postgres "$@" < /dev/null; }
    run_pg_restore(){ "$DOCKER_CMD" exec -i "$CONTAINER_NAME" pg_restore -U postgres "$@"; }
else
    LOCAL_TMP="$(mktemp -d "${TMPDIR:-/tmp}/bngdrasil-verify-XXXXXX")"
    bk_log "임시 PostgreSQL 클러스터 생성: $LOCAL_TMP/data"
    "$(pgbin initdb)" -D "$LOCAL_TMP/data" --auth=trust --no-locale --encoding=UTF8 \
        > "$LOCAL_TMP/initdb.log" 2>&1 || bk_fail "initdb 실패. $LOCAL_TMP/initdb.log 참고"
    "$(pgbin pg_ctl)" -D "$LOCAL_TMP/data" -l "$LOCAL_TMP/server.log" \
        -o "-k $LOCAL_TMP -h '' -p $PORT" -w start > /dev/null 2>&1 \
        || bk_fail "임시 클러스터를 시작하지 못했습니다. $LOCAL_TMP/server.log 참고"
    LOCAL_STARTED=1
    run_psql()      { "$(pgbin psql)" -X -h "$LOCAL_TMP" -p "$PORT" "$@" < /dev/null; }
    run_createdb()  { "$(pgbin createdb)" -h "$LOCAL_TMP" -p "$PORT" "$@" < /dev/null; }
    run_pg_restore(){ "$(pgbin pg_restore)" -h "$LOCAL_TMP" -p "$PORT" "$@"; }
fi

# --- 복원과 계수 ---------------------------------------------------------------
TABLE_QUERY="SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema') AND table_type='BASE TABLE' ORDER BY 1"

for dump in "$DUMP_DIR"/postgresql-*.dump; do
    [ -e "$dump" ] || continue
    db_name="$(basename "$dump")"
    db_name="${db_name#postgresql-}"
    db_name="${db_name%.dump}"
    target_db="verify_${db_name}"
    status="passed"
    detail=""
    checksum_state="missing"

    if [ -r "$dump.sha256" ]; then
        expected="$(awk '{print $1}' "$dump.sha256")"
        actual="$(bk_sha256_value "$dump")"
        if [ "$expected" = "$actual" ]; then
            checksum_state="matched"
        else
            checksum_state="mismatch"
            status="failed"
            detail="저장된 sha256 과 실제 값이 다릅니다."
            FAILED_DBS=$((FAILED_DBS + 1))
        fi
    fi

    tables=0
    total_rows=0
    row_entries=""

    if [ "$status" = "passed" ]; then
        if ! run_createdb "$target_db" >/dev/null 2>&1; then
            status="failed"; detail="격리 DB 생성 실패: $target_db"; FAILED_DBS=$((FAILED_DBS + 1))
        elif ! run_pg_restore --exit-on-error --no-owner --no-privileges -d "$target_db" < "$dump" \
                > /dev/null 2>&1; then
            status="failed"; detail="pg_restore 실패"; FAILED_DBS=$((FAILED_DBS + 1))
        else
            while IFS= read -r qualified; do
                [ -n "$qualified" ] || continue
                schema="${qualified%%.*}"
                table="${qualified#*.}"
                count="$(run_psql -Atc "SELECT count(*) FROM \"$schema\".\"$table\"" -d "$target_db" | tr -d '\r')"
                case "$count" in ''|*[!0-9]*) count=0 ;; esac
                tables=$((tables + 1))
                total_rows=$((total_rows + count))
                if [ -n "$row_entries" ]; then row_entries="$row_entries, "; fi
                row_entries="$row_entries$(bk_json_kv_raw "$qualified" "$count")"
            done <<< "$(run_psql -Atc "$TABLE_QUERY" -d "$target_db" | tr -d '\r')"
        fi
    fi

    json_append "{$(bk_json_kv name "$db_name"), $(bk_json_kv dump "$(basename "$dump")"), $(bk_json_kv checksum "$checksum_state"), $(bk_json_kv restore "$status"), $(bk_json_kv_raw tables "$tables"), $(bk_json_kv_raw total_rows "$total_rows"), $(bk_json_kv_raw row_counts "{${row_entries}}"), $(bk_json_kv detail "$detail")}"
    bk_log "복원 결과: $db_name -> $status (테이블 ${tables}개, 행 ${total_rows}개)"
done

[ -n "$RESULTS" ] || bk_fail "복원할 dump 파일을 찾지 못했습니다: $DUMP_DIR"

if [ "$FAILED_DBS" -gt 0 ]; then
    BK_ERROR="${FAILED_DBS}개의 데이터베이스에서 격리 복원이 실패했습니다."
    exit 1
fi
OVERALL="success"
bk_log "격리 복원 검증 성공 (PostgreSQL $PG_VERSION)"
