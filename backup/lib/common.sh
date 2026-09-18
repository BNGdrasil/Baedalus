#!/usr/bin/env bash
# BNGdrasil backup shared helpers.
# Sourced by every script in this directory. Not executable on its own.
#
# Configuration precedence: process environment > /etc/bngdrasil-backup/env > defaults below.

# --- paths -------------------------------------------------------------------
BK_ENV_FILE="${BK_ENV_FILE:-/etc/bngdrasil-backup/env}"
BK_SECRET_DIR="${BK_SECRET_DIR:-/etc/bngdrasil-backup}"

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
    mkdir -p "$BACKUP_ROOT" "$STATE_DIR" "$LOCK_DIR"
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

bk_acquire_lock() {
    local name="$1"
    if command -v flock >/dev/null 2>&1; then
        BK_LOCK_PATH="$LOCK_DIR/$name.lock"
        BK_LOCK_KIND="flock"
        exec 9>"$BK_LOCK_PATH" || return 1
        if ! flock -n 9; then
            bk_err "다른 백업 작업이 이미 실행 중입니다: $BK_LOCK_PATH"
            return 1
        fi
    else
        BK_LOCK_PATH="$LOCK_DIR/$name.lockdir"
        BK_LOCK_KIND="mkdir"
        if ! mkdir "$BK_LOCK_PATH" 2>/dev/null; then
            local owner=""
            owner="$(cat "$BK_LOCK_PATH/pid" 2>/dev/null || true)"
            if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
                bk_err "다른 백업 작업이 이미 실행 중입니다(pid $owner): $BK_LOCK_PATH"
                return 1
            fi
            bk_warn "남아 있는 잠금을 정리하고 다시 획득합니다: $BK_LOCK_PATH"
            rm -rf "$BK_LOCK_PATH"
            mkdir "$BK_LOCK_PATH" 2>/dev/null || return 1
        fi
        printf '%s\n' "$$" > "$BK_LOCK_PATH/pid"
    fi
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
