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

TARGETS_DIR="/opt/bnbong/monitoring/prometheus/targets"
TARGET_FILE="${TARGETS_DIR}/${SERVICE_NAME}.json"

# Check if service already exists
if [ -f "$TARGET_FILE" ]; then
    echo "⚠️  Service ${SERVICE_NAME} already exists!"
    echo "File: ${TARGET_FILE}"
    exit 1
fi

# Create target file
cat > "$TARGET_FILE" << EOF
[
  {
    "targets": ["${SERVICE_NAME}:${PORT}"],
    "labels": {
      "service": "${SERVICE_NAME}",
      "team": "${TEAM}",
      "env": "production"
    }
  }
]
EOF

echo "✅ Added ${SERVICE_NAME} to Prometheus targets"
echo "📁 File: ${TARGET_FILE}"
echo "⏱️  Prometheus will detect it within 30 seconds"
echo ""
echo "To verify:"
echo "  curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.service==\"${SERVICE_NAME}\")'"

