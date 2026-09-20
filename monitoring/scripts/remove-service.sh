#!/bin/bash
# Remove MSA service from Prometheus monitoring
# Usage: ./remove-service.sh <service-name>

set -euo pipefail

SERVICE_NAME=${1:-}

if [ -z "$SERVICE_NAME" ]; then
    echo "Usage: $0 <service-name>"
    echo "Example: $0 user-service"
    exit 1
fi

# TARGETS_DIR을 환경 변수로 덮어쓸 수 있게 둔다. list-services.sh, add-service.sh와 같은
# 형태이며 운영 기본값은 그대로다.
TARGETS_DIR="${TARGETS_DIR:-/opt/bnbong/monitoring/prometheus/targets}"

# --- 인자 검증 ---------------------------------------------------------------
# add-service.sh와 같은 규칙을 그대로 둔다. 같은 이름 공간을 다루므로 규칙이 갈라지면
# 등록은 되는데 제거는 안 되는 이름이 생긴다.
#
# 규칙을 공용 라이브러리로 빼지 않고 양쪽에 둔 이유: 이 두 스크립트는 운영 중에
# VM2에서 개별 파일로 실행되며, source 할 파일이 옆에 없으면 곧바로 실패한다.
# remote-exporters/lib/common.sh 처럼 공용 파일을 만들면 배포 경로에 의존성이 하나 더
# 늘어난다. 중복되는 것은 정규식 한 줄과 검증 함수 하나뿐이라, 그 비용보다 단독 실행
# 가능성을 지키는 쪽이 낫다고 보았다. 한쪽을 고치면 다른 쪽도 함께 고쳐야 한다.
#
# 검증 자체가 필요한 이유는 add-service.sh와 같다. 허용 문자에 / 와 . 이 없으므로
# ../../etc/passwd 같은 인자가 TARGETS_DIR 밖의 파일을 지우는 경로가 성립하지 않고,
# "-" 로 시작하는 옵션 모양의 인자도 함께 걸린다.
NAME_PATTERN='^[a-z0-9][a-z0-9_-]*$'
NAME_MAX_LEN=63

if [ "${#SERVICE_NAME}" -gt "$NAME_MAX_LEN" ]; then
    echo "❌ Invalid service name: too long (${#SERVICE_NAME} characters, max ${NAME_MAX_LEN})" >&2
    exit 1
fi
if [[ ! "$SERVICE_NAME" =~ $NAME_PATTERN ]]; then
    echo "❌ Invalid service name: '${SERVICE_NAME}'" >&2
    echo "   Allowed: lowercase letters, digits, '-' and '_'; must start with a letter or digit." >&2
    echo "   Rejected because it could point outside ${TARGETS_DIR}." >&2
    exit 1
fi

TARGET_FILE="${TARGETS_DIR}/${SERVICE_NAME}.json"

# 락 파일을 열려면 디렉터리가 있어야 한다. 없을 때 exec 리다이렉션 오류를 그대로
# 내보내면 원인이 드러나지 않으므로 먼저 확인한다. add-service.sh와 같은 검사다.
if [ ! -d "$TARGETS_DIR" ]; then
    echo "❌ Targets directory not found: ${TARGETS_DIR}" >&2
    exit 1
fi

# --- targets 디렉터리 배타 락 -------------------------------------------------
# add-service.sh와 같은 락을 같은 방식으로 건다. 근거는 그쪽 주석에 적어 두었고,
# 여기에서 락을 걸지 않으면 존재 확인과 rm 사이에 add가 끼어들어 "제거했다"는
# 보고와 달리 target이 살아 있는 상태가 남는다. 한쪽을 고치면 다른 쪽도 함께
# 고쳐야 한다는 위의 규칙이 락에도 그대로 적용된다.
LOCK_FILE="${TARGETS_DIR}/.targets.lock"
LOCK_WAIT_SECONDS=10

if ! command -v flock >/dev/null 2>&1; then
    echo "❌ flock not found. Refusing to modify ${TARGETS_DIR} without a lock." >&2
    echo "   Install util-linux (Ubuntu: apt-get install util-linux)." >&2
    exit 1
fi

exec 9>"$LOCK_FILE" || {
    echo "❌ Failed to open the lock file: ${LOCK_FILE}" >&2
    exit 1
}
if ! flock -w "$LOCK_WAIT_SECONDS" 9; then
    echo "❌ Another add-service.sh or remove-service.sh is holding the lock on ${TARGETS_DIR}." >&2
    echo "   Waited ${LOCK_WAIT_SECONDS}s. Try again." >&2
    exit 1
fi

if [ ! -f "$TARGET_FILE" ]; then
    echo "⚠️  Service ${SERVICE_NAME} not found!"
    exit 1
fi

# Backup before removal
#
# 백업 사본을 같은 디렉터리에 두어도 Prometheus가 읽지 않는다. msa-services job의
# file_sd glob이 targets/*.json 이고, 파일 이름이 .json.bak 으로 끝나서 그 glob에
# 걸리지 않기 때문이다. list-services.sh도 같은 *.json 목록만 훑으므로 제거한 서비스가
# 목록에 다시 나타나지도 않는다. 사본을 옮길 곳을 따로 만들면 운영자가 되돌릴 때 찾아야 할
# 경로가 늘어나므로, 원본 옆에 그대로 둔다.
cp -- "$TARGET_FILE" "${TARGET_FILE}.bak"

# Remove target file
rm -- "$TARGET_FILE"

echo "✅ Removed ${SERVICE_NAME} from Prometheus targets"
echo "📁 Backup: ${TARGET_FILE}.bak"
echo "⏱️  Prometheus will stop scraping it within 30 seconds"
