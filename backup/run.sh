#!/usr/bin/env bash
#
# 백업 전체 실행. systemd 의 bngdrasil-backup.service 가 이 파일을 실행한다.
#
# 순서는 PostgreSQL, Redis, SQLite, 보존 정책, 집계 metric 이다. 앞 단계가 실패해도
# 뒤 단계를 계속 수행하되 실패 건수를 모아 마지막에 non-zero 로 끝낸다. 보존 정책은
# 실패한 구성 요소를 스스로 건너뛰므로 여기에서 따로 막지 않는다.

set -uo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

# BK_COMPONENT 는 lib/common.sh 의 로그 함수가 읽는다.
# shellcheck disable=SC2034
BK_COMPONENT="run"
bk_load_env

# 실행 대상 정의. /etc/bngdrasil-backup/env 에서 덮어쓸 수 있다.
#   REDIS_TARGETS  : "이름:모드:대상[:포트]" 를 공백으로 구분
#   SQLITE_TARGETS : "이름:절대경로" 를 공백으로 구분
# 값을 빈 문자열로 두면 해당 종류를 아예 실행하지 않는다.
REDIS_TARGETS="${REDIS_TARGETS-vm3:container:vm3-redis}"
SQLITE_TARGETS="${SQLITE_TARGETS-}"
# VM2 처럼 호스트 PostgreSQL 이 없는 서버에서는 false 로 두어 PostgreSQL 단계를 건너뛴다.
RUN_POSTGRESQL="${RUN_POSTGRESQL:-true}"
RUN_RETENTION="${RUN_RETENTION:-1}"
RUN_NOTIFY="${RUN_NOTIFY:-1}"

STARTED_AT="$(bk_now_iso)"
FAILURES=0
FAILED_STEPS=""
OK_STEPS=""

step() {
    # step <이름> <명령...>
    local name="$1"; shift
    bk_log "단계 시작: $name"
    if "$@"; then
        bk_log "단계 성공: $name"
        OK_STEPS="$OK_STEPS $name"
        return 0
    fi
    bk_err "단계 실패: $name"
    FAILURES=$((FAILURES + 1))
    FAILED_STEPS="$FAILED_STEPS $name"
    return 1
}

case "$RUN_POSTGRESQL" in
    true|1|yes) step "postgresql" "$BK_SCRIPT_DIR/pg-backup.sh" || true ;;
    false|0|no) bk_log "RUN_POSTGRESQL 이 $RUN_POSTGRESQL 이므로 PostgreSQL 단계를 건너뜁니다." ;;
    *) bk_warn "RUN_POSTGRESQL 값을 해석하지 못했습니다($RUN_POSTGRESQL). 기본 동작으로 실행합니다."
       step "postgresql" "$BK_SCRIPT_DIR/pg-backup.sh" || true ;;
esac

for entry in $REDIS_TARGETS; do
    [ -n "$entry" ] || continue
    IFS=':' read -r r_name r_mode r_target r_port <<< "$entry"
    if [ -z "${r_name:-}" ] || [ -z "${r_mode:-}" ] || [ -z "${r_target:-}" ]; then
        bk_warn "REDIS_TARGETS 항목 형식이 올바르지 않아 건너뜁니다: $entry"
        continue
    fi
    step "redis-$r_name" "$BK_SCRIPT_DIR/redis-backup.sh" \
        --name "$r_name" --mode "$r_mode" --target "$r_target" --port "${r_port:-6379}" || true
done

for entry in $SQLITE_TARGETS; do
    [ -n "$entry" ] || continue
    s_name="${entry%%:*}"
    s_path="${entry#*:}"
    if [ -z "$s_name" ] || [ -z "$s_path" ] || [ "$s_name" = "$s_path" ]; then
        bk_warn "SQLITE_TARGETS 항목 형식이 올바르지 않아 건너뜁니다: $entry"
        continue
    fi
    step "sqlite-$s_name" "$BK_SCRIPT_DIR/sqlite-backup.sh" --name "$s_name" --source "$s_path" || true
done

if [ "$RUN_RETENTION" = "1" ]; then
    step "retention" "$BK_SCRIPT_DIR/retention.sh" || true
fi

# --- 집계 상태 ----------------------------------------------------------------
FINISHED_AT="$(bk_now_iso)"
if [ "$FAILURES" -eq 0 ]; then
    OVERALL="success"
    bk_write_metrics "all" 0 "$(bk_now_epoch)"
else
    OVERALL="failed"
    bk_write_metrics "all" 1 "$(bk_last_success_field "$STATE_DIR/last-success.json" finished_epoch || true)"
fi

{
    echo "{"
    printf '  %s,\n' "$(bk_json_kv component "all")"
    printf '  %s,\n' "$(bk_json_kv status "$OVERALL")"
    printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
    printf '  %s,\n' "$(bk_json_kv finished_at "$FINISHED_AT")"
    printf '  %s,\n' "$(bk_json_kv_raw finished_epoch "$(bk_now_epoch)")"
    printf '  %s,\n' "$(bk_json_kv_raw failures "$FAILURES")"
    printf '  %s,\n' "$(bk_json_kv succeeded_steps "${OK_STEPS# }")"
    printf '  %s\n'  "$(bk_json_kv failed_steps "${FAILED_STEPS# }")"
    echo "}"
} | bk_write_file "$STATE_DIR/last-run.json"

if [ "$OVERALL" = "success" ]; then
    cp -p "$STATE_DIR/last-run.json" "$STATE_DIR/last-success.json"
fi

if [ "$RUN_NOTIFY" = "1" ] && [ -x "$BK_SCRIPT_DIR/notify.sh" ]; then
    if [ "$OVERALL" = "success" ]; then
        [ "${NOTIFY_ON_SUCCESS:-0}" = "1" ] && \
            "$BK_SCRIPT_DIR/notify.sh" success all "완료한 단계:${OK_STEPS}" || true
    else
        "$BK_SCRIPT_DIR/notify.sh" failure all "실패한 단계:${FAILED_STEPS}" || true
    fi
fi

bk_log "전체 결과: $OVERALL (실패 ${FAILURES}건)"
[ "$FAILURES" -eq 0 ] || exit 1
