#!/usr/bin/env bash
#
# 보존 정책 적용. 성공한 백업 디렉터리만 세대별로 남기고 나머지를 지운다.
#
# 기본 정책은 일 7세대, 주 4세대, 월 3세대이다. 같은 날에 여러 번 실행했다면 그 날의
# 가장 최근 성공본만 일 세대로 계산한다. 주와 월도 같은 방식이다.
#
# 안전 장치
#   - 성공한 백업이 하나뿐이면 어떤 경우에도 삭제하지 않는다.
#   - 해당 구성 요소의 마지막 실행이 실패 상태이면 그 구성 요소의 정리를 건너뛴다.
#   - SUCCESS 표시가 없는 디렉터리는 세대로 계산하지 않으며, RETENTION_FAILED_DAYS 를
#     넘긴 실패 디렉터리는 성공본이 남아 있을 때만 정리한다.
#
#   ./retention.sh            정책 적용
#   ./retention.sh --dry-run  삭제 대상만 출력

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

# BK_COMPONENT 는 lib/common.sh 의 로그 함수가 읽는다.
# shellcheck disable=SC2034
BK_COMPONENT="retention"
bk_load_env

RETENTION_DAILY="${RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-4}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-3}"
RETENTION_FAILED_DAYS="${RETENTION_FAILED_DAYS:-7}"

DRY_RUN=0
[ "${1:-}" != "--dry-run" ] || DRY_RUN=1

REMOVED=0
KEPT=0
SKIPPED=""

on_exit() {
    local rc=$?
    bk_release_lock
    return "$rc"
}
trap on_exit EXIT
bk_acquire_lock "retention" || exit 1

# run id(YYYYMMDDTHHMMSSZ) 를 일·주·월 키로 바꾸고 세대 정책을 적용한다.
# 주 번호는 로케일과 date 구현에 의존하지 않도록 율리우스 적일에서 직접 계산한다.
classify() {
    awk -v daily="$RETENTION_DAILY" -v weekly="$RETENTION_WEEKLY" -v monthly="$RETENTION_MONTHLY" '
        function jdn(y, m, d,   a, yy, mm) {
            a = int((14 - m) / 12)
            yy = y + 4800 - a
            mm = m + 12 * a - 3
            return d + int((153 * mm + 2) / 5) + 365 * yy + int(yy / 4) - int(yy / 100) + int(yy / 400) - 32045
        }
        {
            path = $0
            n = split(path, parts, "/")
            id = parts[n]
            year  = substr(id, 1, 4) + 0
            month = substr(id, 5, 2) + 0
            day   = substr(id, 7, 2) + 0
            dkey = substr(id, 1, 8)
            mkey = substr(id, 1, 6)
            # mawk 의 기본 CONVFMT 로 지수 표기가 섞이지 않도록 정수 문자열로 만든다.
            wkey = sprintf("%d", int(jdn(year, month, day) / 7))
            keep = 0
            if (!(dkey in seen_day) && days < daily)      { seen_day[dkey] = 1; days++;   keep = 1 }
            if (!(wkey in seen_week) && weeks < weekly)   { seen_week[wkey] = 1; weeks++; keep = 1 }
            if (!(mkey in seen_month) && months < monthly){ seen_month[mkey] = 1; months++; keep = 1 }
            print (keep ? "KEEP" : "DROP") "\t" path
        }'
}

apply_group() {
    # apply_group <그룹 디렉터리> <상태 파일 접두사>
    local group_dir="$1" state_name="$2"
    [ -d "$group_dir" ] || return 0

    local last_run="$STATE_DIR/$state_name-last-run.json"
    if [ -r "$last_run" ]; then
        local status
        status="$(bk_last_success_field "$last_run" status || true)"
        if [ "$status" != "success" ]; then
            bk_warn "마지막 실행이 성공 상태가 아니므로 정리를 건너뜁니다: $group_dir (status=$status)"
            SKIPPED="$SKIPPED $group_dir"
            return 0
        fi
    fi

    local success_list
    success_list="$(find "$group_dir" -mindepth 1 -maxdepth 1 -type d -exec test -e '{}/SUCCESS' ';' -print 2>/dev/null | sort -r || true)"
    local success_count=0
    [ -z "$success_list" ] || success_count="$(printf '%s\n' "$success_list" | wc -l | tr -d ' ')"

    if [ "$success_count" -le 1 ]; then
        bk_log "성공한 백업이 ${success_count}개뿐이므로 삭제하지 않습니다: $group_dir"
        KEPT=$((KEPT + success_count))
        return 0
    fi

    local line decision path
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        decision="${line%%	*}"
        path="${line#*	}"
        if [ "$decision" = "KEEP" ]; then
            KEPT=$((KEPT + 1))
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            bk_log "삭제 예정: $path"
        else
            rm -rf "$path"
            bk_log "삭제: $path"
        fi
        REMOVED=$((REMOVED + 1))
    done <<< "$(printf '%s\n' "$success_list" | classify)"

    # 실패 디렉터리는 성공본이 남아 있을 때만, 그리고 지정한 기간이 지난 뒤에만 정리한다.
    local failed
    while IFS= read -r failed; do
        [ -n "$failed" ] || continue
        if [ "$DRY_RUN" -eq 1 ]; then
            bk_log "실패 디렉터리 삭제 예정: $failed"
        else
            rm -rf "$failed"
            bk_log "실패 디렉터리 삭제: $failed"
        fi
    done <<< "$(find "$group_dir" -mindepth 1 -maxdepth 1 -type d -mtime "+$RETENTION_FAILED_DAYS" \
                    -exec test -e '{}/FAILED' ';' -print 2>/dev/null || true)"
}

apply_group "$BACKUP_ROOT/postgresql" "postgresql"

for dir in "$BACKUP_ROOT"/redis/*; do
    [ -d "$dir" ] || continue
    apply_group "$dir" "redis-$(basename "$dir")"
done

for dir in "$BACKUP_ROOT"/sqlite/*; do
    [ -d "$dir" ] || continue
    apply_group "$dir" "sqlite-$(basename "$dir")"
done

bk_log "보존 정책 적용 완료. 유지 ${KEPT}개, 삭제 ${REMOVED}개."
[ -z "$SKIPPED" ] || bk_log "건너뛴 그룹:$SKIPPED"
