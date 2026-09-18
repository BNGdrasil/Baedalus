#!/usr/bin/env bash
#
# 독립 보관 전송. 성공한 백업 디렉터리를 묶어 암호화한 뒤 VM3 밖의 보관 위치로 보낸다.
#
# 기본 대상은 VM4(10.1.2.111)이며 VM2 를 경유하는 SSH 위에서 rsync 를 사용한다.
# SSH 설정과 개인 키는 /etc/bngdrasil-backup/ssh/ 아래 0600 파일에서 읽고 -F 와 -i 로
# 명시한다. root 홈의 ~/.ssh 는 사용하지 않는다.
# 전송 실패는 non-zero 로 끝나지만 로컬의 성공 백업은 그대로 둔다. 로컬에 정상본이
# 하나뿐인 상황에서 전송 실패로 그 본을 잃지 않도록 이 스크립트는 아무것도 지우지 않는다.
#
# 전송한 뒤에는 원격에서 sha256 값을 다시 확인하고, 그 확인을 통과한 경우에만 SHIPPED
# 표시를 남긴다. retention.sh 는 이 표시가 있는 성공본만 세대 계산에 넣으므로, 검증을
# 건너뛴 채 표시를 남기면 오프사이트 사본이 없는 백업이 삭제될 수 있다.
# run.sh 와 retention.sh 와 같은 공용 잠금(BK_LOCK_FILE)을 사용한다. run.sh 안에서
# 순차로 실행될 때에는 BK_LOCK_HELD 를 물려받아 잠금을 다시 얻지 않는다.
#
# 암호화 키는 /etc/bngdrasil-backup/ 아래 0600 파일에서만 읽으며 스크립트에 값을 두지 않는다.
#   age  : $BK_SECRET_DIR/age-recipients.txt (공개 수신자 목록. 복호화 키는 보관 측에 둔다)
#   gpg  : $BK_SECRET_DIR/gpg-passphrase     (대칭 암호 passphrase)
#
# OCI Object Storage 대안은 README.md 의 "독립 보관" 절에 절차를 적어 두었다.
#
#   ./ship.sh              아직 보내지 않은 성공본을 전송
#   ./ship.sh --all        이미 보낸 것까지 다시 전송
#   ./ship.sh --dry-run    대상만 출력

set -euo pipefail
umask 077

BK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$BK_SCRIPT_DIR/lib/common.sh"

# BK_COMPONENT 는 lib/common.sh 의 로그 함수가 읽는다.
# shellcheck disable=SC2034
BK_COMPONENT="ship"
bk_load_env

SHIP_TARGET="${SHIP_TARGET:-}"
SHIP_SSH_HOST="${SHIP_SSH_HOST:-bngdrasil-vm4}"
SHIP_SSH_OPTS="${SHIP_SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
# SSH 설정과 키는 root 홈이 아니라 /etc/bngdrasil-backup/ssh/ 아래에 둔다.
# systemd 유닛이 ProtectHome=yes 로 실행하므로 root 홈의 ~/.ssh 에는 닿지 않는다.
SHIP_SSH_DIR="${SHIP_SSH_DIR:-$BK_SECRET_DIR/ssh}"
SHIP_SSH_CONFIG="${SHIP_SSH_CONFIG:-$SHIP_SSH_DIR/config}"
SHIP_SSH_IDENTITY="${SHIP_SSH_IDENTITY:-$SHIP_SSH_DIR/id_ed25519}"
SHIP_SSH_KNOWN_HOSTS="${SHIP_SSH_KNOWN_HOSTS:-$SHIP_SSH_DIR/known_hosts}"
SHIP_REMOTE_DIR="${SHIP_REMOTE_DIR:-/var/backups/bngdrasil-offsite}"
SHIP_ENCRYPTION="${SHIP_ENCRYPTION:-age}"
SHIP_OUTBOUND_DIR="${SHIP_OUTBOUND_DIR:-$BACKUP_ROOT/outbound}"
AGE_RECIPIENTS_FILE="${AGE_RECIPIENTS_FILE:-$BK_SECRET_DIR/age-recipients.txt}"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-$BK_SECRET_DIR/gpg-passphrase}"
# 원격 검증 설정. 0 으로 두면 검증을 건너뛰지만 그 경우에도 경고를 남긴다.
SHIP_VERIFY="${SHIP_VERIFY:-1}"
SHIP_VERIFY_SSH_HOST="${SHIP_VERIFY_SSH_HOST:-$SHIP_SSH_HOST}"
SHIP_VERIFY_REMOTE_DIR="${SHIP_VERIFY_REMOTE_DIR:-$SHIP_REMOTE_DIR}"

STATE_LAST_RUN="$STATE_DIR/ship-last-run.json"
STATE_LAST_SUCCESS="$STATE_DIR/ship-last-success.json"

MODE_ALL=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --all)     MODE_ALL=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "알 수 없는 인자입니다: $arg" >&2; exit 2 ;;
    esac
done

BK_ERROR=""
STARTED_AT="$(bk_now_iso)"
SENT=0
FAILED=0
# 전송 도중에 중단되더라도 SHIPPING 표시가 남지 않도록 현재 대상 디렉터리를 기억한다.
CURRENT_SHIPPING=""

write_state() {
    local status="$1"
    local error_json="null"
    [ -z "$BK_ERROR" ] || error_json="\"$(bk_json_escape "$BK_ERROR")\""
    {
        echo "{"
        printf '  %s,\n' "$(bk_json_kv component "ship")"
        printf '  %s,\n' "$(bk_json_kv status "$status")"
        printf '  %s,\n' "$(bk_json_kv started_at "$STARTED_AT")"
        printf '  %s,\n' "$(bk_json_kv finished_at "$(bk_now_iso)")"
        printf '  %s,\n' "$(bk_json_kv_raw finished_epoch "$(bk_now_epoch)")"
        printf '  %s,\n' "$(bk_json_kv destination "${SHIP_TARGET:-$SHIP_SSH_HOST:$SHIP_REMOTE_DIR}")"
        printf '  %s,\n' "$(bk_json_kv_raw shipped "$SENT")"
        printf '  %s,\n' "$(bk_json_kv_raw failed "$FAILED")"
        printf '  %s\n'  "$(bk_json_kv_raw error "$error_json")"
        echo "}"
    } | bk_write_file "$STATE_LAST_RUN"
    [ "$status" != "success" ] || cp -p "$STATE_LAST_RUN" "$STATE_LAST_SUCCESS"
}

on_exit() {
    local rc=$?
    [ -z "$CURRENT_SHIPPING" ] || rm -f "$CURRENT_SHIPPING/SHIPPING"
    if [ "$DRY_RUN" -eq 1 ]; then
        bk_release_lock
        return "$rc"
    fi
    if [ "$rc" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
        write_state "success"
        bk_write_metrics "ship" 0 "$(bk_now_epoch)"
    else
        [ -n "$BK_ERROR" ] || BK_ERROR="ship.sh 가 exit code $rc 로 종료했습니다."
        write_state "failed"
        bk_write_metrics "ship" 1 "$(bk_last_success_field "$STATE_LAST_SUCCESS" finished_epoch || true)"
    fi
    bk_write_unshipped_metrics
    bk_release_lock
    return "$rc"
}
trap on_exit EXIT
bk_acquire_pipeline_lock || exit 1

require_secret_file() {
    local file="$1"
    [ -r "$file" ] || bk_fail "암호화 키 파일을 읽을 수 없습니다: $file"
    local mode=""
    mode="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo '')"
    case "$mode" in
        600|400) : ;;
        '') bk_warn "권한을 확인하지 못했습니다: $file" ;;
        *)  bk_fail "암호화 키 파일 권한이 너무 넓습니다(현재 $mode). 600 으로 바꾸십시오: $file" ;;
    esac
}

# ssh 호출에 쓸 옵션을 한 곳에서 조립한다. 설정 파일과 키를 -F 와 -i 로 명시하므로
# root 홈의 ~/.ssh 에 의존하지 않는다.
SSH_ARGS=""
build_ssh_args() {
    # shellcheck disable=SC2086
    set -- $SHIP_SSH_OPTS
    local args=("$@")
    if [ -r "$SHIP_SSH_CONFIG" ]; then
        require_secret_file "$SHIP_SSH_CONFIG"
        args+=(-F "$SHIP_SSH_CONFIG")
    else
        bk_warn "SSH 설정 파일이 없습니다. 기본값으로 접속을 시도합니다: $SHIP_SSH_CONFIG"
        args+=(-F /dev/null)
    fi
    if [ -r "$SHIP_SSH_IDENTITY" ]; then
        require_secret_file "$SHIP_SSH_IDENTITY"
        args+=(-i "$SHIP_SSH_IDENTITY" -o IdentitiesOnly=yes)
    fi
    args+=(-o "UserKnownHostsFile=$SHIP_SSH_KNOWN_HOSTS")
    SSH_ARGS="${args[*]}"
}
build_ssh_args

case "$SHIP_ENCRYPTION" in
    age)
        command -v age >/dev/null 2>&1 || bk_fail "age 가 설치되어 있지 않습니다."
        require_secret_file "$AGE_RECIPIENTS_FILE"
        ;;
    gpg)
        command -v gpg >/dev/null 2>&1 || bk_fail "gpg 가 설치되어 있지 않습니다."
        require_secret_file "$GPG_PASSPHRASE_FILE"
        ;;
    none)
        bk_fail "암호화 없이 전송하지 않습니다. SHIP_ENCRYPTION 을 age 또는 gpg 로 설정하십시오."
        ;;
    *) bk_fail "지원하지 않는 SHIP_ENCRYPTION 값입니다: $SHIP_ENCRYPTION" ;;
esac

command -v rsync >/dev/null 2>&1 || bk_fail "rsync 가 설치되어 있지 않습니다."
mkdir -p "$SHIP_OUTBOUND_DIR"

destination="${SHIP_TARGET:-$SHIP_SSH_HOST:$SHIP_REMOTE_DIR}"

encrypt_stream() {
    # 표준 입력의 tar 스트림을 암호화하여 표준 출력으로 내보낸다.
    case "$SHIP_ENCRYPTION" in
        age) age --encrypt --recipients-file "$AGE_RECIPIENTS_FILE" ;;
        gpg) gpg --batch --yes --symmetric --cipher-algo AES256 \
                 --passphrase-file "$GPG_PASSPHRASE_FILE" --output - ;;
    esac
}

# 원격에 도착한 아카이브의 sha256 값을 원격에서 다시 계산하여 대조한다. 이 검사를
# 통과하지 못하면 SHIPPED 표시를 남기지 않으므로 보존 정책이 원본을 지우지 않는다.
verify_remote() {
    # verify_remote <아카이브 파일 이름>
    local name="$1"
    if [ "$SHIP_VERIFY" = "0" ]; then
        bk_warn "SHIP_VERIFY 가 0 이므로 원격 검증을 건너뛰고 전송 완료로 기록합니다: $name"
        return 0
    fi
    local remote_cmd
    remote_cmd="cd '$SHIP_VERIFY_REMOTE_DIR' && if command -v sha256sum >/dev/null 2>&1; then sha256sum -c '$name.sha256'; else shasum -a 256 -c '$name.sha256'; fi"
    # shellcheck disable=SC2086,SC2029
    if ssh $SSH_ARGS "$SHIP_VERIFY_SSH_HOST" "$remote_cmd" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

ship_one() {
    # ship_one <백업 run 디렉터리> <아카이브 이름 접두사>
    local run_dir="$1" label="$2"
    local run_id parent ext archive name
    run_id="$(basename "$run_dir")"
    parent="$(dirname "$run_dir")"
    case "$SHIP_ENCRYPTION" in
        age) ext="tar.gz.age" ;;
        gpg) ext="tar.gz.gpg" ;;
    esac
    name="${label}-${run_id}.${ext}"
    archive="$SHIP_OUTBOUND_DIR/$name"

    if [ "$DRY_RUN" -eq 1 ]; then
        bk_log "전송 예정: $run_dir -> $destination/$name"
        return 0
    fi

    # 전송이 진행 중임을 표시한다. retention.sh 가 이 표시를 보고 정리에서 제외한다.
    : > "$run_dir/SHIPPING"
    CURRENT_SHIPPING="$run_dir"

    rm -f "$archive.partial"
    if ! tar -C "$parent" -czf - "$run_id" | encrypt_stream > "$archive.partial"; then
        rm -f "$archive.partial" "$run_dir/SHIPPING"
        CURRENT_SHIPPING=""
        bk_err "암호화 아카이브 생성 실패: $run_dir"
        FAILED=$((FAILED + 1))
        return 1
    fi
    if [ ! -s "$archive.partial" ]; then
        rm -f "$archive.partial" "$run_dir/SHIPPING"
        CURRENT_SHIPPING=""
        bk_err "암호화 결과가 비어 있습니다: $run_dir"
        FAILED=$((FAILED + 1))
        return 1
    fi
    mv "$archive.partial" "$archive"
    # 체크섬 파일에는 상대 이름만 적는다. 원격에서 sha256sum -c 로 그대로 대조하기 위해서이다.
    ( cd "$SHIP_OUTBOUND_DIR" && bk_sha256_file "$name" ) > "$archive.sha256"

    # 파일 권한은 umask 077 로 이미 600 이고 rsync -a 가 그대로 보존한다.
    if ! rsync -a --partial -e "ssh $SSH_ARGS" \
            "$archive" "$archive.sha256" "$destination/"; then
        bk_err "rsync 전송 실패: $archive"
        # 전송하지 못한 암호화 사본은 디스크에 남기지 않는다. 원본 백업은 그대로 둔다.
        rm -f "$archive" "$archive.sha256" "$run_dir/SHIPPING"
        CURRENT_SHIPPING=""
        FAILED=$((FAILED + 1))
        return 1
    fi

    if ! verify_remote "$name"; then
        bk_err "원격 체크섬 검증에 실패했습니다. SHIPPED 표시를 남기지 않습니다: $name"
        # 깨진 원격 사본이 정상본처럼 남지 않도록 지운다. 실패해도 진행에는 영향이 없다.
        # shellcheck disable=SC2086,SC2029
        ssh $SSH_ARGS "$SHIP_VERIFY_SSH_HOST" \
            "rm -f '$SHIP_VERIFY_REMOTE_DIR/$name' '$SHIP_VERIFY_REMOTE_DIR/$name.sha256'" \
            >/dev/null 2>&1 || bk_warn "원격의 불완전한 사본을 지우지 못했습니다: $name"
        rm -f "$archive" "$archive.sha256" "$run_dir/SHIPPING"
        CURRENT_SHIPPING=""
        FAILED=$((FAILED + 1))
        return 1
    fi

    : > "$run_dir/SHIPPED"
    rm -f "$run_dir/SHIPPING"
    CURRENT_SHIPPING=""
    SENT=$((SENT + 1))
    bk_log "전송 완료: $name"
    # 전송한 암호화 사본은 로컬에서 지운다. 원본 백업 디렉터리는 그대로 둔다.
    rm -f "$archive" "$archive.sha256"
    return 0
}

collect_and_ship() {
    # collect_and_ship <그룹 디렉터리> <라벨>
    local group_dir="$1" label="$2" dir
    [ -d "$group_dir" ] || return 0
    for dir in "$group_dir"/*; do
        [ -d "$dir" ] || continue
        [ -e "$dir/SUCCESS" ] || continue
        if [ "$MODE_ALL" -eq 0 ] && [ -e "$dir/SHIPPED" ]; then
            continue
        fi
        ship_one "$dir" "$label" || true
    done
}

# 원격 보관 디렉터리를 준비한다. SHIP_TARGET 을 직접 지정한 경우에는 건너뛴다.
if [ "$DRY_RUN" -eq 0 ] && [ -z "$SHIP_TARGET" ]; then
    # SHIP_REMOTE_DIR 는 의도적으로 로컬에서 확장한다.
    # shellcheck disable=SC2086,SC2029
    ssh $SSH_ARGS "$SHIP_SSH_HOST" "mkdir -p '$SHIP_REMOTE_DIR' && chmod 700 '$SHIP_REMOTE_DIR'" \
        || bk_fail "원격 보관 디렉터리를 준비하지 못했습니다: $SHIP_SSH_HOST:$SHIP_REMOTE_DIR"
fi

collect_and_ship "$BACKUP_ROOT/postgresql" "postgresql"
for d in "$BACKUP_ROOT"/redis/*;  do [ -d "$d" ] && collect_and_ship "$d" "redis-$(basename "$d")"  || true; done
for d in "$BACKUP_ROOT"/sqlite/*; do [ -d "$d" ] && collect_and_ship "$d" "sqlite-$(basename "$d")" || true; done

bk_log "전송 결과: 성공 ${SENT}건, 실패 ${FAILED}건."
if [ "$FAILED" -gt 0 ]; then
    BK_ERROR="${FAILED}건의 전송이 실패했습니다. 로컬 백업은 그대로 유지합니다."
    exit 1
fi
