#!/bin/bash
# Add new MSA service to Prometheus monitoring
# Usage: ./add-service.sh <service-name> <port> [team]

set -euo pipefail

SERVICE_NAME=${1:-}
PORT=${2:-}
TEAM=${3:-development}

if [ -z "$SERVICE_NAME" ] || [ -z "$PORT" ]; then
    echo "Usage: $0 <service-name> <port> [team]"
    echo "Example: $0 user-service 8002 backend"
    exit 1
fi

# TARGETS_DIR을 환경 변수로 덮어쓸 수 있게 둔다. list-services.sh가 이미 같은 형태이고,
# 운영 기본값은 그대로이므로 동작이 달라지지 않는다. 시험할 때 임시 디렉터리를 지정해서
# 운영 경로를 건드리지 않고 돌릴 수 있다는 이점이 있다.
TARGETS_DIR="${TARGETS_DIR:-/opt/bnbong/monitoring/prometheus/targets}"

# --- 인자 검증 ---------------------------------------------------------------
# 서비스 이름은 파일 이름(${TARGETS_DIR}/<이름>.json)과 scrape target의 호스트 이름으로
# 동시에 쓰인다. 그래서 두 가지를 모두 만족해야 한다.
#   - 경로 구분자와 점을 막는다. 허용 문자에 / 와 . 이 없으므로 ../ 나 절대 경로로
#     TARGETS_DIR 밖에 파일을 쓰는 경로 이탈이 성립하지 않고, "." 과 ".." 도 걸러진다.
#   - JSON 문자열 안에 그대로 들어가므로 " 와 \ 와 제어 문자를 막는다. 허용 문자 목록
#     방식이라 이 세 가지가 자동으로 빠진다.
#   - 앞 글자를 영숫자로 제한하면 "-" 로 시작하는, 옵션처럼 보이는 인자도 함께 막힌다.
# 길이 상한 63은 이 이름이 컨테이너 네트워크의 호스트 이름으로 해석되기 때문이다.
# DNS label 한도가 63자다. 밑줄은 기존 규칙을 따라 허용하지만, 호스트 이름으로는 권장되지
# 않으므로 새 서비스는 하이픈을 쓰는 편이 낫다.
NAME_PATTERN='^[a-z0-9][a-z0-9_-]*$'
NAME_MAX_LEN=63

# validate_name <값> <인자 이름> : 통과하지 못하면 이유를 적고 1로 끝낸다.
validate_name() {
    local value="$1" label="$2"
    if [ "${#value}" -gt "$NAME_MAX_LEN" ]; then
        echo "❌ Invalid ${label}: too long (${#value} characters, max ${NAME_MAX_LEN})" >&2
        return 1
    fi
    if [[ ! "$value" =~ $NAME_PATTERN ]]; then
        echo "❌ Invalid ${label}: '${value}'" >&2
        echo "   Allowed: lowercase letters, digits, '-' and '_'; must start with a letter or digit." >&2
        echo "   Rejected because it would escape the targets directory or break the JSON file." >&2
        return 1
    fi
    return 0
}

validate_name "$SERVICE_NAME" "service name" || exit 1

# team은 파일 경로에 쓰이지 않으므로 경로 이탈의 위험은 없다. 그러나 JSON 문자열 값으로
# 그대로 들어가기 때문에 " 하나만 섞여도 파일이 깨지고, 깨진 파일을 file_sd가 통째로
# 무시해서 수집이 조용히 멈춘다. 이름과 위험의 종류가 같으므로 같은 규칙을 적용한다.
# Prometheus label 값 자체는 임의의 UTF-8을 허용하지만, 지금 쓰이는 값은 platform,
# identity, infrastructure 처럼 모두 이 규칙 안에 들어온다. 더 넓게 열어야 할 이유가
# 생기기 전까지는 좁게 둔다.
validate_name "$TEAM" "team" || exit 1

# 포트는 1~65535 정수만 받는다. 앞자리를 [1-9]로 고정해서 0, 선행 0(08000), 빈 문자열을
# 막고, 자릿수를 5자리 이하로 제한한 뒤 범위를 본다. [[ =~ ]]의 ^ 와 $ 는 문자열 전체를
# 고정하므로 "8000 "처럼 공백이 붙은 값, "8000abc", "-1" 도 모두 걸린다.
if [[ ! "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$PORT" -gt 65535 ]; then
    echo "❌ Invalid port: '${PORT}'" >&2
    echo "   Port must be an integer between 1 and 65535 (no leading zeros, no spaces)." >&2
    exit 1
fi

TARGET_FILE="${TARGETS_DIR}/${SERVICE_NAME}.json"

if [ ! -d "$TARGETS_DIR" ]; then
    echo "❌ Targets directory not found: ${TARGETS_DIR}" >&2
    exit 1
fi

# --- targets 디렉터리 배타 락 -------------------------------------------------
# 존재 확인과 쓰기 사이에 락이 없으면 동시 실행이 경쟁한다. add-service.sh 두 개가
# 같은 이름으로 동시에 들어오면 둘 다 "없다"를 보고 둘 다 성공을 출력하는데, 실제로
# 남는 파일은 나중에 mv한 쪽 하나뿐이다. add와 remove가 겹치면 지운 직후에 만들어져
# "제거했다"는 보고와 달리 target이 살아 있는 상태도 생긴다. 파일 내용 자체는
# mktemp + mv 덕분에 깨지지 않지만, 보고와 결과가 어긋나는 것은 그대로 남는다.
#
# 락 단위를 파일이 아니라 targets 디렉터리로 잡는다. remove-service.sh가 같은 락을
# 쓰며, 서비스 이름이 서로 달라도 같은 디렉터리를 함께 고치기 때문이다. 디렉터리
# 하나에 대한 작업은 밀리초 단위로 끝나므로 경합 비용은 문제가 되지 않는다.
#
# 락 파일 이름을 .targets.lock 으로 둔다. msa-services job의 file_sd glob이
# targets/*.json 이라 이 파일은 걸리지 않고, list-services.sh의 목록에도 나오지
# 않는다. 파일은 한 번 만들어진 뒤 지우지 않는다. 지우면 그 사이에 다른 실행이
# 이미 열어 둔 inode와 새 inode가 갈라져서 락이 성립하지 않는다.
#
# VM2는 Ubuntu이고 flock은 util-linux에 들어 있으므로 반드시 있다. 없으면 락 없이
# 진행하지 않고 분명하게 실패한다. 조용히 넘어가면 락이 있다고 믿은 채로 경쟁이
# 되살아난다.
LOCK_FILE="${TARGETS_DIR}/.targets.lock"
LOCK_WAIT_SECONDS=10

if ! command -v flock >/dev/null 2>&1; then
    echo "❌ flock not found. Refusing to modify ${TARGETS_DIR} without a lock." >&2
    echo "   Install util-linux (Ubuntu: apt-get install util-linux)." >&2
    exit 1
fi

# fd 9를 락 파일에 연다. 이 스크립트가 끝나면 fd가 닫히면서 락이 저절로 풀리므로
# 따로 푸는 절차가 필요 없고, 중간에 죽어도 락이 남지 않는다.
exec 9>"$LOCK_FILE" || {
    echo "❌ Failed to open the lock file: ${LOCK_FILE}" >&2
    exit 1
}
if ! flock -w "$LOCK_WAIT_SECONDS" 9; then
    echo "❌ Another add-service.sh or remove-service.sh is holding the lock on ${TARGETS_DIR}." >&2
    echo "   Waited ${LOCK_WAIT_SECONDS}s. Try again." >&2
    exit 1
fi

# Check if service already exists
if [ -f "$TARGET_FILE" ]; then
    echo "⚠️  Service ${SERVICE_NAME} already exists!"
    echo "File: ${TARGET_FILE}"
    exit 1
fi

# --- target 파일 생성 ---------------------------------------------------------
# JSON을 만드는 방법으로 jq가 아니라 printf를 골랐다. VM2에 jq가 설치되어 있다고 보장할
# 수 없고, 이 스크립트는 수집 대상을 등록하는 쓰기 경로라서 도구가 없다고 실패하면 곤란하기
# 때문이다. list-services.sh는 jq를 쓰지만 그쪽은 조회용이라 없으면 출력만 빈다.
# printf를 쓰면서도 안전한 이유는 서식 문자열이 스크립트에 고정되어 있고, 값은 %s로만
# 들어가며, 그 값들이 위 검증을 통과해 " 와 \ 와 제어 문자를 포함할 수 없기 때문이다.
#
# 임시 파일에 쓴 뒤 mv로 옮긴다. Prometheus는 30초마다 이 디렉터리를 다시 읽으므로,
# 쓰는 도중의 반쪽짜리 파일을 읽을 틈을 없애려는 것이다. mv는 같은 디렉터리 안이라
# 원자적으로 끝난다.
TMP_FILE="$(mktemp "${TARGETS_DIR}/.${SERVICE_NAME}.json.XXXXXX")" ||
    { echo "❌ Failed to create a temporary file in ${TARGETS_DIR}" >&2; exit 1; }
trap 'rm -f -- "$TMP_FILE"' EXIT

printf '[\n  {\n    "targets": ["%s:%s"],\n    "labels": {\n      "service": "%s",\n      "team": "%s",\n      "env": "production"\n    }\n  }\n]\n' \
    "$SERVICE_NAME" "$PORT" "$SERVICE_NAME" "$TEAM" > "$TMP_FILE"

# 만들어진 파일이 실제로 유효한 JSON인지 확인한 뒤에만 자리에 놓는다. 검증을 통과한 값만
# 쓰더라도, 깨진 파일이 들어가면 file_sd가 그 파일을 통째로 무시해서 수집이 조용히 멈추는
# 실패 방식이라 확인 비용이 훨씬 싸다. python3는 Ubuntu 기본 설치에 들어 있고, 없을 때를
# 대비해 jq로 한 번 더 시도한다. 둘 다 없으면 확인만 건너뛰고 등록은 진행한다.
if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP_FILE" 2>/dev/null; then
        echo "❌ Generated file is not valid JSON. Aborting without registering." >&2
        exit 1
    fi
elif command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$TMP_FILE" >/dev/null 2>&1; then
        echo "❌ Generated file is not valid JSON. Aborting without registering." >&2
        exit 1
    fi
else
    echo "⚠️  Neither python3 nor jq found; skipped the JSON syntax check." >&2
fi

chmod 644 "$TMP_FILE"
mv -f -- "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "✅ Added ${SERVICE_NAME} to Prometheus targets"
echo "📁 File: ${TARGET_FILE}"
echo "⏱️  Prometheus will detect it within 30 seconds"
echo ""
# prometheus.yml의 msa-services job은 위 service label을 job label로 옮긴 뒤 target
# label 쪽 service를 지운다. 애플리케이션이 내보내는 service label과 충돌하지 않게
# 하려는 것이며, 그래서 target을 조회할 때에는 service가 아니라 job으로 고른다.
echo "To verify:"
echo "  curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job==\"msa-${SERVICE_NAME}\")'"
