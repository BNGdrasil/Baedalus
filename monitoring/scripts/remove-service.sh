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

TARGETS_DIR="/opt/bnbong/monitoring/prometheus/targets"
TARGET_FILE="${TARGETS_DIR}/${SERVICE_NAME}.json"

if [ ! -f "$TARGET_FILE" ]; then
    echo "⚠️  Service ${SERVICE_NAME} not found!"
    exit 1
fi

# Backup before removal
cp "$TARGET_FILE" "${TARGET_FILE}.bak"

# Remove target file
rm "$TARGET_FILE"

echo "✅ Removed ${SERVICE_NAME} from Prometheus targets"
echo "📁 Backup: ${TARGET_FILE}.bak"
echo "⏱️  Prometheus will stop scraping it within 30 seconds"

