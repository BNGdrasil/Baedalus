#!/usr/bin/env bash
# BNGdrasil 원격 exporter 설치 스크립트가 공유하는 헬퍼.
# install-*.sh 가 source 해서 사용한다. 단독으로 실행하지 않는다.
#
# 공통 규칙
#   - 모든 설치 동작은 ex_run 을 거치므로 --dry-run 에서는 아무것도 바꾸지 않는다.
#   - 설정 파일은 ex_write_file 로 내용을 비교한 뒤 달라졌을 때에만 교체한다.
#     이렇게 해야 같은 인자로 다시 실행해도 서비스를 불필요하게 재시작하지 않는다.
#   - 방화벽(iptables, ufw, OCI security list)은 이 스크립트가 바꾸지 않고 안내만 한다.

# --- 상태 변수 ---------------------------------------------------------------
EX_DRY_RUN="${EX_DRY_RUN:-0}"
EX_COMPONENT="${EX_COMPONENT:-exporter}"
# 직전 ex_write_file / ex_install_binary 가 실제로 무언가를 바꾸었는지 알린다.
EX_CHANGED=0
# 내려받은 파일을 푸는 임시 디렉터리. ex_enable_cleanup 이 EXIT trap 으로 지운다.
EX_TMP_DIR=""

# --- 로그 --------------------------------------------------------------------
ex_log()  { printf '[%s] %s\n' "$EX_COMPONENT" "$*"; }
ex_warn() { printf '[%s] WARN: %s\n' "$EX_COMPONENT" "$*" >&2; }
ex_err()  { printf '[%s] ERROR: %s\n' "$EX_COMPONENT" "$*" >&2; }
ex_fail() { ex_err "$*"; exit 1; }

# --- 실행 래퍼 ---------------------------------------------------------------
# ex_run <명령...> : dry-run 이면 실행하지 않고 그대로 출력한다.
ex_run() {
    if [ "$EX_DRY_RUN" -eq 1 ]; then
        printf '[%s] (dry-run) %s\n' "$EX_COMPONENT" "$*"
        return 0
    fi
    "$@"
}

ex_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# 스크립트가 어떤 경로로 끝나더라도 임시 디렉터리를 남기지 않도록 EXIT trap 을 건다.
ex_enable_cleanup() {
    trap 'if [ -n "${EX_TMP_DIR:-}" ]; then rm -rf "$EX_TMP_DIR"; fi' EXIT
}

ex_require_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    # EX_ALLOW_NONROOT 은 회귀 시험이 root 없이 사전 점검 경로를 돌리기 위한 seam 이다.
    # 기본값이 0 이므로 운영 동작은 달라지지 않는다.
    if [ "${EX_ALLOW_NONROOT:-0}" -eq 1 ]; then
        ex_warn "EX_ALLOW_NONROOT 이 켜져 있어서 root 확인을 건너뜁니다. 시험용 설정입니다."
        return 0
    fi
    if [ "$EX_DRY_RUN" -eq 1 ]; then
        ex_warn "root 권한이 아니지만 dry-run 이므로 계획만 출력합니다."
        return 0
    fi
    ex_fail "root 권한으로 실행해야 합니다. sudo 를 사용하십시오."
}

ex_require_systemd() {
    ex_have_cmd systemctl || ex_fail "systemctl 이 없습니다. 이 스크립트는 systemd 호스트 전용입니다."
}

# --- 인자 검증 ---------------------------------------------------------------
# ex_validate_ipv4 <주소> : 점 네 자리 IPv4 인지 확인한다.
ex_validate_ipv4() {
    local ip="$1" part
    case "$ip" in
        *.*.*.*) ;;
        *) return 1 ;;
    esac
    local IFS=.
    # shellcheck disable=SC2086
    set -- $ip
    [ "$#" -eq 4 ] || return 1
    for part in "$@"; do
        case "$part" in
            ''|*[!0-9]*) return 1 ;;
        esac
        [ "$part" -le 255 ] || return 1
    done
    return 0
}

ex_validate_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# --- 아키텍처 판별 -------------------------------------------------------------
# 릴리스 자산 이름에 쓰는 이름(amd64 또는 arm64)을 표준 출력으로 돌려준다.
ex_detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        *) ex_fail "지원하지 않는 아키텍처입니다: $machine. amd64 와 arm64 만 다룹니다." ;;
    esac
}

# --- 다운로드와 무결성 검증 ------------------------------------------------------
ex_download() {
    local url="$1" dest="$2"
    if ex_have_cmd curl; then
        curl -fsSL --retry 3 --retry-delay 2 --max-time 180 -o "$dest" "$url" ||
            ex_fail "내려받지 못했습니다: $url"
    elif ex_have_cmd wget; then
        wget -q -T 180 -t 3 -O "$dest" "$url" ||
            ex_fail "내려받지 못했습니다: $url"
    else
        ex_fail "curl 과 wget 이 모두 없어서 파일을 내려받을 수 없습니다."
    fi
}

ex_sha256_value() {
    if ex_have_cmd sha256sum; then
        sha256sum "$1" | awk '{print $1}'
    elif ex_have_cmd shasum; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        ex_fail "sha256sum 과 shasum 이 모두 없어서 무결성을 확인할 수 없습니다."
    fi
}

# ex_binary_version_matches <바이너리 경로> <버전 문자열>
# 이미 설치된 바이너리가 같은 버전인지 확인한다. 멱등성을 여기에서 얻는다.
ex_binary_version_matches() {
    local path="$1" version="$2"
    [ -x "$path" ] || return 1
    "$path" --version 2>&1 | grep -Fq -- "$version"
}

# ex_install_binary <표시 이름> <버전> <자산 URL> <체크섬 URL> <자산 파일 이름> <바이너리 이름> <설치 경로>
#
# 체크섬은 스크립트에 적어 두지 않고 릴리스가 함께 배포하는 sha256sums 파일을 받아서
# 대조한다. 값을 소스에 고정하면 아키텍처마다 값이 달라 관리가 어렵고, 값을 잘못
# 적었을 때 설치가 조용히 막히기 때문이다.
ex_install_binary() {
    local label="$1" version="$2" asset_url="$3" sums_url="$4"
    local asset_name="$5" bin_name="$6" dest="$7"
    local tmp_dir expected actual found

    EX_CHANGED=0
    if ex_binary_version_matches "$dest" "$version"; then
        ex_log "$label $version 바이너리가 이미 $dest 에 있으므로 내려받지 않습니다."
        return 0
    fi

    if [ "$EX_DRY_RUN" -eq 1 ]; then
        ex_log "(dry-run) $asset_url 를 내려받고 sha256 을 $sums_url 와 대조한 뒤 $dest 에 설치합니다."
        EX_CHANGED=1
        return 0
    fi

    tmp_dir="$(mktemp -d)" || ex_fail "임시 디렉터리를 만들지 못했습니다."
    # ex_fail 은 exit 로 끝나므로 함수 지역 trap 으로는 정리되지 않는다. 경로를 전역에
    # 남겨 두고, 스크립트가 ex_enable_cleanup 으로 걸어 둔 EXIT trap 이 지우게 한다.
    EX_TMP_DIR="$tmp_dir"

    ex_log "$label $version 을 내려받습니다: $asset_url"
    ex_download "$asset_url" "$tmp_dir/$asset_name"
    ex_download "$sums_url" "$tmp_dir/sha256sums.txt"

    expected="$(awk -v name="$asset_name" '$2 == name || $2 == "*" name {print $1; exit}' "$tmp_dir/sha256sums.txt")"
    [ -n "$expected" ] || ex_fail "체크섬 목록에서 $asset_name 항목을 찾지 못했습니다."
    actual="$(ex_sha256_value "$tmp_dir/$asset_name")"
    if [ "$expected" != "$actual" ]; then
        ex_fail "sha256 이 일치하지 않습니다. 기대값 $expected, 실제값 $actual"
    fi
    ex_log "sha256 검증을 통과했습니다: $actual"

    tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir" || ex_fail "압축을 풀지 못했습니다: $asset_name"
    # 릴리스마다 압축 안의 디렉터리 구조가 다르므로 이름으로 찾는다.
    found="$(find "$tmp_dir" -type f -name "$bin_name" -perm -u+x | head -n1)"
    [ -n "$found" ] || ex_fail "압축 안에서 $bin_name 실행 파일을 찾지 못했습니다."

    install -d -m 0755 "$(dirname "$dest")"
    install -m 0755 -o root -g root "$found" "$dest"
    ex_log "$dest 에 $label $version 을 설치했습니다."
    rm -rf "$tmp_dir"
    EX_TMP_DIR=""
    EX_CHANGED=1
}

# --- 전용 시스템 사용자 ---------------------------------------------------------
ex_ensure_system_user() {
    local user="$1"
    if id -u "$user" >/dev/null 2>&1; then
        ex_log "시스템 사용자 $user 가 이미 있으므로 그대로 사용합니다."
        return 0
    fi
    ex_log "시스템 사용자 $user 를 만듭니다. 로그인과 홈 디렉터리는 두지 않습니다."
    ex_run useradd --system --no-create-home --shell /usr/sbin/nologin "$user" ||
        ex_fail "시스템 사용자 $user 를 만들지 못했습니다."
}

# --- 파일 쓰기 ---------------------------------------------------------------
# ex_write_file <경로> <권한> [소유자]
# 내용은 표준 입력으로 받는다. 기존 내용과 같으면 아무것도 하지 않고 EX_CHANGED=0 으로
# 둔다. 호출하는 쪽은 이 값을 보고 서비스를 재시작할지 결정한다.
ex_write_file() {
    local dest="$1" mode="$2" owner="${3:-root:root}" content tmp
    content="$(cat)"
    EX_CHANGED=0

    if [ -f "$dest" ] && printf '%s\n' "$content" | cmp -s - "$dest"; then
        ex_log "$dest 의 내용이 이미 같으므로 그대로 둡니다."
        return 0
    fi
    # 이 값은 호출하는 install-*.sh 가 재시작 여부를 결정할 때 읽는다.
    # shellcheck disable=SC2034
    EX_CHANGED=1

    if [ "$EX_DRY_RUN" -eq 1 ]; then
        ex_log "(dry-run) $dest 를 권한 $mode, 소유자 $owner 로 새로 씁니다."
        return 0
    fi

    install -d -m 0755 "$(dirname "$dest")"
    tmp="$dest.tmp.$$"
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    chown "$owner" "$tmp"
    mv -f "$tmp" "$dest"
    ex_log "$dest 를 갱신했습니다."
}

# --- systemd 적용 -------------------------------------------------------------
# ex_apply_unit <유닛 이름> <유닛 파일이 바뀌었으면 1>
ex_apply_unit() {
    local unit="$1" changed="$2"
    ex_run systemctl daemon-reload
    # enable 이 실패하면 부팅 후에 exporter 가 살아나지 않으므로 그대로 중단한다.
    ex_run systemctl enable "$unit" || ex_fail "$unit 을 enable 하지 못했습니다."

    if [ "$EX_DRY_RUN" -eq 1 ]; then
        ex_log "(dry-run) $unit 을 기동하거나, 설정이 바뀌었다면 재시작합니다."
        return 0
    fi

    if systemctl is-active --quiet "$unit"; then
        if [ "$changed" -eq 1 ]; then
            ex_log "설정이 바뀌었으므로 $unit 을 재시작합니다."
            systemctl restart "$unit"
        else
            ex_log "설정이 그대로이므로 $unit 을 재시작하지 않습니다."
        fi
    else
        ex_log "$unit 을 기동합니다."
        systemctl start "$unit"
    fi
}

# ex_remove_unit <유닛 이름> <유닛 파일 경로>
ex_remove_unit() {
    local unit="$1" path="$2"
    ex_run systemctl disable --now "$unit" >/dev/null 2>&1 || true
    ex_run rm -f "$path"
    ex_run systemctl daemon-reload
    ex_log "$unit 을 중지하고 유닛 파일을 제거했습니다."
}

# --- 검증 --------------------------------------------------------------------
# ex_check_metrics <주소> <포트> : 기동 직후에 /metrics 가 응답하는지 본다.
ex_check_metrics() {
    local addr="$1" port="$2" line=""
    if [ "$EX_DRY_RUN" -eq 1 ]; then
        ex_log "(dry-run) curl http://$addr:$port/metrics 로 응답을 확인합니다."
        return 0
    fi
    ex_have_cmd curl || { ex_warn "curl 이 없어서 응답 확인을 건너뜁니다."; return 0; }
    # 기동 직후에는 소켓이 아직 열리지 않을 수 있으므로 몇 초 동안 다시 시도한다.
    for _ in 1 2 3 4 5; do
        line="$(curl -sf --max-time 5 "http://$addr:$port/metrics" 2>/dev/null | head -n1 || true)"
        [ -z "$line" ] || break
        sleep 2
    done
    if [ -n "$line" ]; then
        ex_log "http://$addr:$port/metrics 가 응답합니다: $line"
        return 0
    fi
    ex_warn "http://$addr:$port/metrics 에서 응답을 받지 못했습니다. journalctl 로 유닛 로그를 확인하십시오."
    return 1
}

# --- 설치 전 사전 점검 ----------------------------------------------------------
# 아래 함수들은 install-*.sh 가 바이너리를 내려받기 전에 호출한다. 이미 다른 방식으로
# 같은 exporter 가 떠 있는 호스트에 유닛을 덮어씌우면, 포트를 먼저 잡은 쪽이 남고
# 새 유닛은 조용히 기동에 실패하기 때문이다. 점검은 --dry-run 에서도 그대로 수행한다.
# 우회 플래그는 일부러 만들지 않았다. 기존 설치를 정리하는 절차를 사람이 밟아야 한다.

# 직전 ex_listen_raw 가 사용한 조회 도구 이름이다. pid 를 뽑을 때 형식이 달라서 남긴다.
EX_LISTEN_TOOL=""

# ex_listen_tool : 이 호스트에서 쓸 수 있는 소켓 조회 도구 이름을 돌려준다.
# 도구가 하나도 없으면 1 로 끝낸다. ex_listen_raw 를 명령 치환으로 부르면 그 안에서 정한
# 값이 부모 셸에 남지 않으므로, 도구 판별을 이렇게 따로 떼어 두었다.
ex_listen_tool() {
    if ex_have_cmd ss; then echo "ss"; return 0; fi
    if ex_have_cmd netstat; then echo "netstat"; return 0; fi
    if ex_have_cmd lsof; then echo "lsof"; return 0; fi
    return 1
}

# ex_listen_raw <포트> : 그 포트를 듣고 있는 소켓 줄만 표준 출력으로 돌려준다.
# 조회 수단이 하나도 없으면 2 로 끝낸다.
ex_listen_raw() {
    local port="$1" suf=":$1"
    # 지정 주소 바인딩과 와일드카드 바인딩(*:9100, 0.0.0.0:9100, [::]:9100)을 모두 잡으려고
    # 주소 전체가 아니라 끝의 ":포트" 부분만 본다.
    if ex_have_cmd ss; then
        EX_LISTEN_TOOL="ss"
        ss -H -ltnp 2>/dev/null | awk -v suf="$suf" \
            'length($4) >= length(suf) && substr($4, length($4) - length(suf) + 1) == suf'
        return 0
    fi
    if ex_have_cmd netstat; then
        EX_LISTEN_TOOL="netstat"
        netstat -ltnp 2>/dev/null | awk -v suf="$suf" \
            'length($4) >= length(suf) && substr($4, length($4) - length(suf) + 1) == suf'
        return 0
    fi
    if ex_have_cmd lsof; then
        EX_LISTEN_TOOL="lsof"
        lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1'
        return 0
    fi
    EX_LISTEN_TOOL=""
    return 2
}

# ex_listen_pids <ex_listen_raw 출력> : 도구별 형식에서 pid 만 뽑는다.
ex_listen_pids() {
    local raw="$1"
    [ -n "$raw" ] || return 0
    case "$EX_LISTEN_TOOL" in
        ss)      printf '%s\n' "$raw" | grep -oE 'pid=[0-9]+' | cut -d= -f2 ;;
        netstat) printf '%s\n' "$raw" | awk '{print $NF}' | cut -d/ -f1 | grep -E '^[0-9]+$' ;;
        lsof)    printf '%s\n' "$raw" | awk '{print $2}' | grep -E '^[0-9]+$' ;;
        *)       return 0 ;;
    esac | sort -u
}

# ex_pid_in_unit <pid> <유닛 이름> : 그 pid 가 이 스크립트가 관리하는 유닛의 것인지 본다.
# 유닛의 MainPID 와 대조하고, 주 프로세스가 아닌 자식이 소켓을 잡은 경우까지 걸러 내려고
# /proc/<pid>/cgroup 에 유닛 이름이 들어 있는지도 함께 확인한다.
ex_pid_in_unit() {
    local pid="$1" unit="$2" main=""
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    if ex_have_cmd systemctl; then
        main="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
        if [ -n "$main" ] && [ "$main" != "0" ] && [ "$main" = "$pid" ]; then
            return 0
        fi
    fi
    if [ -r "/proc/$pid/cgroup" ]; then
        if grep -q -e "/${unit}\$" -e "/${unit}/" "/proc/$pid/cgroup"; then
            return 0
        fi
    fi
    return 1
}

# ex_check_port_free <포트> <자기 유닛 이름>
# 대상 포트를 이미 누군가 듣고 있으면, 그것이 같은 유닛(자기 자신의 재설치)일 때에만
# 통과시키고 나머지 경우에는 점유 프로세스를 보여 준 뒤 1 로 끝낸다.
ex_check_port_free() {
    local port="$1" unit="$2" raw="" pids="" pid foreign=0
    if ! EX_LISTEN_TOOL="$(ex_listen_tool)"; then
        ex_warn "ss 와 netstat 와 lsof 가 모두 없어서 $port 포트의 점유 여부를 확인하지 못했습니다."
        return 0
    fi
    raw="$(ex_listen_raw "$port")"
    if [ -z "$raw" ]; then
        ex_log "$port 포트를 듣고 있는 프로세스가 없습니다."
        return 0
    fi

    pids="$(ex_listen_pids "$raw")"
    if [ -z "$pids" ]; then
        # 권한이 부족하면 조회 결과에 pid 가 비어서 나온다. 판별할 수 없으므로 충돌로 본다.
        foreign=1
    else
        for pid in $pids; do
            if ex_pid_in_unit "$pid" "$unit"; then
                continue
            fi
            foreign=1
        done
    fi

    if [ "$foreign" -eq 0 ]; then
        ex_log "$port 포트는 이미 $unit 이 듣고 있습니다. 같은 유닛을 다시 설치합니다."
        return 0
    fi

    ex_err "$port 포트를 이 스크립트가 관리하지 않는 프로세스가 이미 듣고 있습니다."
    printf '%s\n' "$raw" >&2
    if [ -n "$pids" ] && ex_have_cmd ps; then
        for pid in $pids; do
            ps -o pid=,user=,args= -p "$pid" 2>/dev/null >&2 || true
        done
    fi
    ex_err "먼저 기존 프로세스를 정리해야 합니다. remote-exporters/README.md 의"
    ex_err "\"컨테이너에서 systemd 유닛으로 전환하는 절차\" 절을 따르십시오."
    exit 1
}

# ex_check_no_docker_exporter <컨테이너 이름> <이미지 이름 앞부분>
# 중지된 컨테이너까지 함께 본다. restart 정책이 unless-stopped 이면 호스트가 재부팅될 때
# 되살아나서 새 유닛과 포트를 다투기 때문이다.
ex_check_no_docker_exporter() {
    local want_name="$1" want_image="$2" out="" matches=""
    if ! ex_have_cmd docker; then
        ex_log "docker 명령이 없으므로 컨테이너 점검은 건너뜁니다."
        return 0
    fi
    if ! out="$(docker ps -a --no-trunc --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null)"; then
        ex_warn "docker ps 를 실행하지 못했습니다. 데몬이 멈추었는지 확인하고 컨테이너 점검은 직접 하십시오."
        return 0
    fi
    matches="$(printf '%s\n' "$out" | awk -F'|' -v n="$want_name" -v i="$want_image" \
        'NF > 0 && ($1 == n || index($2, i) == 1)')"
    if [ -z "$matches" ]; then
        ex_log "이름이 $want_name 이거나 이미지가 $want_image 인 컨테이너는 없습니다."
        return 0
    fi

    ex_err "같은 역할을 하는 Docker 컨테이너가 남아 있습니다. 설치를 진행하지 않습니다."
    printf '%s\n' "$matches" >&2
    ex_err "아래 명령으로 정리한 뒤에 다시 실행하십시오."
    printf '%s\n' "  sudo docker stop $want_name && sudo docker rm $want_name" >&2
    ex_err "전환 절차와 되돌리는 방법은 remote-exporters/README.md 의"
    ex_err "\"컨테이너에서 systemd 유닛으로 전환하는 절차\" 절에 있습니다."
    exit 1
}

# ex_dir_mode <경로> : 8진수 권한을 돌려준다. GNU stat 과 BSD stat 을 모두 다룬다.
ex_dir_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1" 2>/dev/null
}

# ex_dir_others_exec <경로> : others 실행 비트가 있으면 0 을 돌려준다.
ex_dir_others_exec() {
    local mode
    mode="$(ex_dir_mode "$1")" || return 1
    [ -n "$mode" ] || return 1
    [ "$(( 8#$mode & 1 ))" -eq 1 ]
}

# ex_ensure_traversable <목표 디렉터리>
# 비root 서비스 사용자가 목표 디렉터리까지 내려가려면 경로 위의 모든 디렉터리에 others
# 실행 비트가 있어야 한다. VM3 의 /var/lib/node_exporter 가 0700 으로 남아 있어서 실제로
# 이 조건이 깨져 있었다.
#
# 고치는 범위는 좁게 잡는다. 시스템 디렉터리(/, /var, /var/lib 등)의 권한을 이 스크립트가
# 바꾸면 영향이 exporter 밖으로 번지기 때문이다. 목표 디렉터리 자신과, 이름이
# node_exporter 계열인 디렉터리, 그리고 그 아래에 있는 디렉터리만 0755 로 고친다.
# 이 세 가지는 모두 exporter 전용이거나 이 스크립트가 만든 경로다.
ex_ensure_traversable() {
    local target="$1" acc="" part dir base
    local -a chain=() parts=()
    local sysdirs=" / /usr /usr/local /var /var/lib /var/local /etc /opt /srv /run /home /tmp "
    local under_exporter=0 fixable

    case "$target" in
        /*) ;;
        *) ex_fail "ex_ensure_traversable 에는 절대 경로를 넘겨야 합니다: $target" ;;
    esac

    IFS='/' read -r -a parts <<< "${target#/}"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        acc="$acc/$part"
        chain+=("$acc")
    done

    for dir in "${chain[@]}"; do
        base="${dir##*/}"
        case "$base" in
            node_exporter|node-exporter) under_exporter=1 ;;
        esac
        # 아직 없는 디렉터리는 뒤에서 install -d -m 0755 로 만들어지므로 건너뛴다.
        [ -d "$dir" ] || continue
        if ex_dir_others_exec "$dir"; then
            continue
        fi

        fixable=0
        if [ "$under_exporter" -eq 1 ] || [ "$dir" = "$target" ]; then
            fixable=1
        fi
        case "$sysdirs" in
            *" $dir "*) fixable=0 ;;
        esac

        if [ "$fixable" -eq 1 ]; then
            ex_log "$dir 에 others 실행 비트가 없어서 0755 로 고칩니다. 현재 권한은 $(ex_dir_mode "$dir") 입니다."
            ex_run chmod 0755 "$dir"
        else
            ex_warn "$dir 의 권한이 $(ex_dir_mode "$dir") 이라서 서비스 사용자가 지나갈 수 없습니다."
            ex_warn "시스템 디렉터리이거나 exporter 전용 경로가 아니므로 이 스크립트는 고치지 않습니다. 직접 확인하십시오."
        fi
    done
}

# ex_verify_user_can_read_dir <사용자> <디렉터리>
# 설치를 마친 뒤에 서비스 사용자로 실제 읽기를 해 본다. 여기에서 실패하면 textfile 지표가
# 통째로 비게 되고 BackupStale 경보가 잘못 울리므로, 경고가 아니라 오류로 끝낸다.
ex_verify_user_can_read_dir() {
    local user="$1" dir="$2"
    local -a runner=()
    if [ "$EX_DRY_RUN" -eq 1 ]; then
        ex_log "(dry-run) 서비스 사용자 $user 로 $dir 를 읽을 수 있는지 확인합니다."
        return 0
    fi
    if ex_have_cmd runuser; then
        runner=(runuser -u "$user" --)
    elif ex_have_cmd sudo; then
        runner=(sudo -n -u "$user" --)
    else
        ex_warn "runuser 와 sudo 가 모두 없어서 서비스 사용자 권한 확인을 건너뜁니다."
        return 0
    fi
    if "${runner[@]}" test -r "$dir" && "${runner[@]}" test -x "$dir"; then
        ex_log "서비스 사용자 $user 가 $dir 를 읽을 수 있습니다."
        return 0
    fi
    ex_err "서비스 사용자 $user 가 $dir 를 읽지 못합니다."
    ex_err "경로 위의 디렉터리 권한을 확인하십시오. 아래 명령으로 어디에서 막히는지 볼 수 있습니다."
    printf '%s\n' "  namei -l $dir" >&2
    exit 1
}

# --- 방화벽 안내 ---------------------------------------------------------------
# 이 스크립트는 방화벽 규칙을 직접 바꾸지 않는다. 운영자가 확인한 뒤에 적용하도록
# 필요한 규칙만 출력한다. Ubuntu 기본 이미지에는 INPUT 사슬 끝부분에 REJECT 규칙이
# 있어서, 허용 규칙을 그 뒤에 넣으면 아무 효과가 없다. 그래서 -I 로 앞에 넣는다.
ex_firewall_hint() {
    local port="$1" bind="$2" allow_from="$3"
    cat <<HINT

[$EX_COMPONENT] 방화벽은 이 스크립트가 바꾸지 않습니다. 아래 두 계층을 직접 확인하십시오.

  1) 호스트 iptables. Ubuntu 기본 규칙에는 INPUT 사슬 끝에 REJECT 가 있으므로,
     허용 규칙을 -A 가 아니라 -I 로 그 앞에 넣어야 실제로 통과합니다.

     sudo iptables -C INPUT -p tcp -s $allow_from --dport $port -j ACCEPT 2>/dev/null \\
       || sudo iptables -I INPUT 1 -p tcp -s $allow_from --dport $port -j ACCEPT
     sudo netfilter-persistent save        # iptables-persistent 를 쓰는 경우

     ufw 를 쓰는 호스트라면 다음 규칙을 사용하십시오.
     sudo ufw allow from $allow_from to $bind port $port proto tcp

  2) OCI security list 또는 network security group.
     같은 VCN 안의 통신이라도 ingress 규칙이 없으면 막힙니다. 콘솔에서 아래 규칙이
     있는지 확인하십시오.
       Source: $allow_from/32, Protocol: TCP, Destination port: $port

  이 포트는 Prometheus 가 있는 $allow_from 에서만 접근할 수 있어야 합니다.
  0.0.0.0/0 으로 여는 규칙이 있다면 제거하십시오.
HINT
}
