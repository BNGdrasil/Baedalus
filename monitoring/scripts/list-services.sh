#!/bin/bash
# List all registered services in Prometheus

set -euo pipefail

TARGETS_DIR="${TARGETS_DIR:-/opt/bnbong/monitoring/prometheus/targets}"
shopt -s nullglob

echo "📊 Registered MSA Services:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for file in ${TARGETS_DIR}/*.json; do
    if [ -f "$file" ]; then
        service=$(basename "$file" .json)
        target=$(jq -r '.[0].targets[0]' "$file" 2>/dev/null) || target="unknown"
        team=$(jq -r '.[0].labels.team' "$file" 2>/dev/null) || team="unknown"
        
        printf "%-20s %-30s [%s]\n" "$service" "$target" "$team"
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To check live status:"
echo "  curl http://localhost:9090/api/v1/targets"

