#!/usr/bin/env bash
# BNGdrasil backup shared helpers.
# Sourced by every script in this directory. Not executable on its own.
#
# Configuration precedence: process environment > /etc/bngdrasil-backup/env > defaults below.

# --- paths -------------------------------------------------------------------
BK_ENV_FILE="${BK_ENV_FILE:-/etc/bngdrasil-backup/env}"
BK_SECRET_DIR="${BK_SECRET_DIR:-/etc/bngdrasil-backup}"

# 스크립트가 처음 실행된 디렉터리를 common.sh 를 불러오는 시점(=아직 아무 데도 cd
# 하기 전)에 기억해 둔다. bk_load_env 가 나중에 cd 를 하더라도, 사용자가 상대 경로로
# 준 인자(예: sqlite-backup.sh --source, verify-restore.sh --dump-dir/--output)를
# 이 값 기준으로 절대 경로로 바꾸면 그 뜻이 그대로 유지된다.
BK_INVOKED_PWD="${BK_INVOKED_PWD:-$PWD}"

# bk_abspath <경로> : 이미 절대 경로이면 그대로, 아니면 BK_INVOKED_PWD 기준의 절대
# 경로로 바꿔 돌려준다. 대상이 실제로 존재할 필요는 없다(출력 파일 경로에도 쓴다).
bk_abspath() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *)  printf '%s/%s\n' "$BK_INVOKED_PWD" "$1" ;;
    esac
}

bk_load_env() {
    if [ -r "$BK_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$BK_ENV_FILE"
    fi
    BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/bngdrasil}"
    STATE_DIR="${STATE_DIR:-$BACKUP_ROOT/state}"
    LOCK_DIR="${LOCK_DIR:-$BACKUP_ROOT/locks}"
    METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile_collector}"
    METRICS_ENABLED="${METRICS_ENABLED:-1}"
    NOTIFY_SCRIPT="${NOTIFY_SCRIPT:-$BK_SCRIPT_DIR/notify.sh}"
    # run.sh, retention.sh, ship.sh 가 공유하는 잠금 파일. 세 스크립트가 같은 백업
    # 디렉터리를 동시에 건드리지 않도록 이름을 하나로 통일한다.
    BK_LOCK_FILE="${BK_LOCK_FILE:-$STATE_DIR/backup.lock}"
    # 공용 잠금을 기다릴 최대 시간(초). 0 이면 기다리지 않고 바로 실패한다.
    BK_LOCK_WAIT_SEC="${BK_LOCK_WAIT_SEC:-300}"
    mkdir -p "$BACKUP_ROOT" "$STATE_DIR" "$LOCK_DIR"
    # sudo 로 홈 디렉터리(예: 소유자만 들어갈 수 있는 /home/ubuntu, 700)에서 이
    # 스크립트를 실행하면, 이후 "sudo -u postgres ..." 로 다른 사용자로 전환하는
    # 하위 프로세스(pg_dump/pg_dumpall/pg_restore 등)가 그 디렉터리에 들어가지
    # 못해 "could not change directory to ..." 경고를 stderr 에 남긴다. 결과에는
    # 영향이 없지만 실행할 때마다 잡음이 남으므로, 모든 사용자가 들어갈 수 있는
    # 디렉터리로 미리 옮겨 둔다. BK_SCRIPT_DIR 등은 이미 이 함수를 부르기 전에
    # BASH_SOURCE 기준 절대 경로로 계산해 두었으므로 cd 뒤에도 그대로 유효하다.
    cd / 2>/dev/null || true
}

# --- logging -----------------------------------------------------------------
bk_log()  { printf '%s [%s] %s\n' "$(bk_now_iso)" "${BK_COMPONENT:-backup}" "$*"; }
bk_warn() { printf '%s [%s] WARN: %s\n' "$(bk_now_iso)" "${BK_COMPONENT:-backup}" "$*" >&2; }
bk_err()  { printf '%s [%s] ERROR: %s\n' "$(bk_now_iso)" "${BK_COMPONENT:-backup}" "$*" >&2; }

# bk_fail <message> : record the message and exit non-zero through the EXIT trap.
bk_fail() {
    BK_ERROR="$*"
    bk_err "$BK_ERROR"
    exit 1
}

# --- time --------------------------------------------------------------------
bk_now_iso()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
bk_now_epoch() { date -u +%s; }
bk_run_id()    { date -u +%Y%m%dT%H%M%SZ; }

# --- portable primitives -----------------------------------------------------
# sha256sum (GNU) and shasum (macOS/BSD) print the same "<hash>  <path>" format.
bk_sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1"
    else
        bk_err "sha256sum 및 shasum 없음"
        return 1
    fi
}

bk_sha256_value() { bk_sha256_file "$1" | awk '{print $1}'; }

bk_file_bytes() { wc -c < "$1" | tr -d ' '; }

# du 와 df 의 KB 값을 awk 로 "추출"만 하고 곱셈은 bash 정수 연산으로 한다.
# mawk 는 큰 수의 산술 결과를 5.12e+09 같은 과학적 표기법으로 출력하기 때문에,
# awk 안에서 곱하면 호출부의 정수 검증에 걸려 디스크 검사가 항상 실패한다.
bk_kb_to_bytes() {
    local kb="$1"
    case "$kb" in
        ''|*[!0-9]*) return 1 ;;
    esac
    echo $(( kb * 1024 ))
}

bk_dir_bytes() {
    [ -d "$1" ] || { echo 0; return 0; }
    local kb=""
    kb="$(du -sk "$1" 2>/dev/null | awk 'NR==1 {print $1}')"
    bk_kb_to_bytes "$kb" || echo 0
}

bk_free_bytes() {
    local kb=""
    kb="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')"
    bk_kb_to_bytes "$kb"
}

# --- locking -----------------------------------------------------------------
# flock(1) when available (Linux), directory lock otherwise (macOS test runs).
BK_LOCK_PATH=""
BK_LOCK_KIND=""

# bk_acquire_lock_file <잠금 파일 경로> [대기 초]
# 지정한 경로를 잠근다. 대기 초를 넘겨 받으면 그 시간까지 다른 작업이 끝나기를
# 기다리고, 그래도 잠기지 않으면 실패한다.
bk_acquire_lock_file() {
    local path="$1" wait_sec="${2:-0}"
    case "$wait_sec" in
        ''|*[!0-9]*) wait_sec=0 ;;
    esac
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then
        BK_LOCK_PATH="$path"
        BK_LOCK_KIND="flock"
        exec 9>"$BK_LOCK_PATH" || return 1
        if [ "$wait_sec" -gt 0 ]; then
            if flock -w "$wait_sec" 9; then
                return 0
            fi
            bk_err "다른 백업 작업이 ${wait_sec}초 동안 끝나지 않아 잠금을 얻지 못했습니다: $BK_LOCK_PATH"
            return 1
        fi
        if ! flock -n 9; then
            bk_err "다른 백업 작업이 이미 실행 중입니다: $BK_LOCK_PATH"
            return 1
        fi
        return 0
    fi

    BK_LOCK_PATH="$path.d"
    BK_LOCK_KIND="mkdir"
    local waited=0
    while true; do
        if mkdir "$BK_LOCK_PATH" 2>/dev/null; then
            printf '%s\n' "$$" > "$BK_LOCK_PATH/pid"
            return 0
        fi
        local owner=""
        owner="$(cat "$BK_LOCK_PATH/pid" 2>/dev/null || true)"
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            bk_warn "남아 있는 잠금을 정리하고 다시 획득합니다: $BK_LOCK_PATH"
            rm -rf "$BK_LOCK_PATH"
            continue
        fi
        if [ "$waited" -ge "$wait_sec" ]; then
            if [ "$wait_sec" -gt 0 ]; then
                bk_err "다른 백업 작업이 ${wait_sec}초 동안 끝나지 않아 잠금을 얻지 못했습니다(pid $owner): $BK_LOCK_PATH"
            else
                bk_err "다른 백업 작업이 이미 실행 중입니다(pid $owner): $BK_LOCK_PATH"
            fi
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# bk_acquire_lock <이름> : 구성 요소별 잠금. LOCK_DIR 아래에 이름별 파일을 만든다.
bk_acquire_lock() {
    bk_acquire_lock_file "$LOCK_DIR/$1.lock" 0
}

# bk_acquire_pipeline_lock : run.sh, retention.sh, ship.sh 가 공유하는 잠금이다.
# run.sh 가 이미 잠금을 보유한 채 두 스크립트를 순차로 실행하는 경우에는
# BK_LOCK_HELD 를 물려받으므로 다시 획득하지 않는다. 이렇게 하여 교착을 피한다.
bk_acquire_pipeline_lock() {
    if [ "${BK_LOCK_HELD:-0}" = "1" ]; then
        BK_LOCK_KIND="inherited"
        BK_LOCK_PATH=""
        bk_log "상위 작업이 공용 잠금을 이미 보유하고 있으므로 다시 획득하지 않습니다."
        return 0
    fi
    bk_acquire_lock_file "$BK_LOCK_FILE" "$BK_LOCK_WAIT_SEC" || return 1
    export BK_LOCK_HELD=1
    return 0
}

bk_release_lock() {
    if [ "$BK_LOCK_KIND" = "mkdir" ] && [ -n "$BK_LOCK_PATH" ]; then
        rm -rf "$BK_LOCK_PATH"
    fi
    BK_LOCK_PATH=""
    BK_LOCK_KIND=""
}

# --- JSON --------------------------------------------------------------------
bk_json_escape() {
    printf '%s' "$1" | awk '
        BEGIN { RS="\n"; ORS="" }
        {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            gsub(/\t/, "\\t")
            gsub(/\r/, "\\r")
            if (NR > 1) printf "\\n"
            printf "%s", $0
        }'
}

# bk_json_kv <key> <string-value> -> "key": "escaped"
bk_json_kv() { printf '"%s": "%s"' "$1" "$(bk_json_escape "$2")"; }

# bk_json_kv_raw <key> <raw-value> -> "key": raw   (numbers, null, nested JSON)
bk_json_kv_raw() { printf '"%s": %s' "$1" "$2"; }

# Write a file atomically with the caller's umask.
bk_write_file() {
    local dest="$1"
    local tmp="$dest.tmp.$$"
    cat > "$tmp"
    mv -f "$tmp" "$dest"
}

# --- Prometheus textfile collector ------------------------------------------
# bk_write_metrics <component> <status-code> <last-success-epoch-or-empty>
# status-code: 0 성공, 1 실패. node_exporter가 읽을 수 있도록 0644로 둔다.
bk_write_metrics() {
    local component="$1" status="$2" success_epoch="$3"
    [ "${METRICS_ENABLED:-1}" = "1" ] || return 0
    [ -n "${METRICS_DIR:-}" ] || return 0
    if ! mkdir -p "$METRICS_DIR" 2>/dev/null; then
        bk_warn "metric 디렉터리를 만들 수 없어 metric 출력을 건너뜁니다: $METRICS_DIR"
        return 0
    fi
    local dest="$METRICS_DIR/bngdrasil-backup-$component.prom"
    local tmp="$dest.tmp.$$"
    {
        echo "# HELP bngdrasil_backup_last_success_timestamp_seconds 마지막으로 성공한 백업의 UNIX 시각."
        echo "# TYPE bngdrasil_backup_last_success_timestamp_seconds gauge"
        if [ -n "$success_epoch" ]; then
            echo "bngdrasil_backup_last_success_timestamp_seconds{component=\"$component\"} $success_epoch"
        fi
        echo "# HELP bngdrasil_backup_last_run_status 마지막 실행 결과. 0은 성공이고 1은 실패이다."
        echo "# TYPE bngdrasil_backup_last_run_status gauge"
        echo "bngdrasil_backup_last_run_status{component=\"$component\"} $status"
        echo "# HELP bngdrasil_backup_last_run_timestamp_seconds 마지막 실행이 끝난 UNIX 시각."
        echo "# TYPE bngdrasil_backup_last_run_timestamp_seconds gauge"
        echo "bngdrasil_backup_last_run_timestamp_seconds{component=\"$component\"} $(bk_now_epoch)"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"
}

# --- notification hook -------------------------------------------------------
bk_notify() {
    local status="$1" component="$2" message="$3"
    [ -x "${NOTIFY_SCRIPT:-}" ] || return 0
    "$NOTIFY_SCRIPT" "$status" "$component" "$message" || \
        bk_warn "알림 전송에 실패했습니다. 백업 결과 자체에는 영향을 주지 않습니다."
}

# --- last-success helper -----------------------------------------------------
# state/last-success.json에서 값을 추출한다. jq 없이 동작해야 하므로 grep을 사용한다.
bk_last_success_field() {
    local file="$1" key="$2"
    [ -r "$file" ] || return 1
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null |
        head -n1 | sed 's/.*:[[:space:]]*//; s/^"//; s/"$//'
}

# --- 백업 그룹과 미전송 집계 ------------------------------------------------------
# 백업 그룹은 "<디렉터리> <탭> <component 라벨>" 한 줄로 표현한다. 라벨은 metric 의
# component 값 및 상태 파일 접두사와 같은 문자열을 사용한다.
bk_backup_groups() {
    local dir
    [ ! -d "$BACKUP_ROOT/postgresql" ] || printf '%s\t%s\n' "$BACKUP_ROOT/postgresql" "postgresql"
    for dir in "$BACKUP_ROOT"/redis/*; do
        [ -d "$dir" ] || continue
        printf '%s\t%s\n' "$dir" "redis-$(basename "$dir")"
    done
    for dir in "$BACKUP_ROOT"/sqlite/*; do
        [ -d "$dir" ] || continue
        printf '%s\t%s\n' "$dir" "sqlite-$(basename "$dir")"
    done
}

# bk_group_unshipped_count <그룹 디렉터리>
# SUCCESS 표시는 있지만 SHIPPED 표시가 없는 실행 디렉터리의 개수를 센다.
bk_group_unshipped_count() {
    local group_dir="$1" dir count=0
    [ -d "$group_dir" ] || { echo 0; return 0; }
    for dir in "$group_dir"/*; do
        [ -d "$dir" ] || continue
        [ -e "$dir/SUCCESS" ] || continue
        [ ! -e "$dir/SHIPPED" ] || continue
        count=$((count + 1))
    done
    echo "$count"
}

# 미전송 성공본 개수를 component 별 gauge 로 내보낸다. BackupUnshippedPileup 경보가
# 이 지표를 읽는다. 사라진 component 의 시계열은 다음 출력에서 빠진다.
bk_write_unshipped_metrics() {
    [ "${METRICS_ENABLED:-1}" = "1" ] || return 0
    [ -n "${METRICS_DIR:-}" ] || return 0
    if ! mkdir -p "$METRICS_DIR" 2>/dev/null; then
        bk_warn "metric 디렉터리를 만들 수 없어 미전송 지표 출력을 건너뜁니다: $METRICS_DIR"
        return 0
    fi
    local dest="$METRICS_DIR/bngdrasil-backup-unshipped.prom"
    local tmp="$dest.tmp.$$"
    {
        echo "# HELP bngdrasil_backup_unshipped_total 아직 독립 보관 위치로 보내지 못한 성공 백업의 개수."
        echo "# TYPE bngdrasil_backup_unshipped_total gauge"
        local line group label
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            group="${line%%	*}"
            label="${line#*	}"
            echo "bngdrasil_backup_unshipped_total{component=\"$label\"} $(bk_group_unshipped_count "$group")"
        done <<< "$(bk_backup_groups)"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dest" 2>/dev/null || rm -f "$tmp"
}
