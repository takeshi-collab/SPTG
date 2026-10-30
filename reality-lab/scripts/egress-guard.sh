#!/usr/bin/env bash
# egress-guard.sh — GCP Egress Circuit Breaker & Safety Monitor
# Location: /usr/local/bin/egress-guard.sh

set -euo pipefail

# Configuration (Environment variables override default placeholders)
INTERFACE="${EGRESS_IFACE:-eth0}"
# Fallback interface detection for GCE (eth0 or ens4)
if [[ ! -d "/sys/class/net/${INTERFACE}" ]]; then
    if [[ -d "/sys/class/net/ens4" ]]; then
        INTERFACE="ens4"
    fi
fi

MONTHLY_LIMIT_GB="${MONTHLY_LIMIT_GB:-180}" # Default threshold: 180 GB
STATE_DIR="/var/lib/egress-guard"
STATE_FILE="${STATE_DIR}/state.json"
LOG_FILE="/var/log/egress-guard.log"

mkdir -p "${STATE_DIR}"

log() {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $1" | tee -a "${LOG_FILE}"
}

# Current month format: YYYY-MM
CURRENT_MONTH=$(date -u '+%Y-%m')

# Read current tx_bytes from sysfs
if [[ ! -f "/sys/class/net/${INTERFACE}/statistics/tx_bytes" ]]; then
    log "ERROR: Interface ${INTERFACE} statistics not found!"
    exit 1
fi

RAW_TX_BYTES=$(cat "/sys/class/net/${INTERFACE}/statistics/tx_bytes")

# Load state
SAVED_MONTH=""
BASE_TX_BYTES=0
ACCUMULATED_BYTES=0
IS_BLOCKED="false"

if [[ -f "${STATE_FILE}" ]]; then
    SAVED_MONTH=$(grep -oP '"month":\s*"\K[^"]+' "${STATE_FILE}" || true)
    BASE_TX_BYTES=$(grep -oP '"base_tx_bytes":\s*\K[0-9]+' "${STATE_FILE}" || echo 0)
    ACCUMULATED_BYTES=$(grep -oP '"accumulated_bytes":\s*\K[0-9]+' "${STATE_FILE}" || echo 0)
    IS_BLOCKED=$(grep -oP '"is_blocked":\s*"\K[^"]+' "${STATE_FILE}" || echo "false")
fi

# If month changed, reset counters
if [[ "${SAVED_MONTH}" != "${CURRENT_MONTH}" ]]; then
    log "New month detected (${CURRENT_MONTH}). Resetting egress quota counters."
    SAVED_MONTH="${CURRENT_MONTH}"
    BASE_TX_BYTES=${RAW_TX_BYTES}
    ACCUMULATED_BYTES=0
    IS_BLOCKED="false"
    # Re-enable service if previously blocked
    systemctl start sing-box 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 443 -j DROP 2>/dev/null || true
fi

# Calculate tx delta since last base reset
if (( RAW_TX_BYTES >= BASE_TX_BYTES )); then
    DELTA_BYTES=$(( RAW_TX_BYTES - BASE_TX_BYTES ))
else
    # Counter wrapped around or reboot happened
    DELTA_BYTES=${RAW_TX_BYTES}
    BASE_TX_BYTES=0
fi

TOTAL_BYTES=$(( ACCUMULATED_BYTES + DELTA_BYTES ))
TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", ${TOTAL_BYTES}/1073741824}")

log "Monthly Egress Status [${CURRENT_MONTH}]: ${TOTAL_GB} GB / ${MONTHLY_LIMIT_GB} GB (Interface: ${INTERFACE})"

# Save state
cat <<EOF > "${STATE_FILE}"
{
  "month": "${CURRENT_MONTH}",
  "base_tx_bytes": ${RAW_TX_BYTES},
  "accumulated_bytes": ${TOTAL_BYTES},
  "is_blocked": "${IS_BLOCKED}",
  "last_check": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

# Check threshold
LIMIT_BYTES=$(( MONTHLY_LIMIT_GB * 1073741824 ))

if (( TOTAL_BYTES >= LIMIT_BYTES )); then
    if [[ "${IS_BLOCKED}" != "true" ]]; then
        log "CRITICAL: Monthly egress quota exceeded (${TOTAL_GB} GB >= ${MONTHLY_LIMIT_GB} GB)! Triggering circuit breaker..."

        # 1. Stop sing-box proxy service
        systemctl stop sing-box || log "WARNING: Failed to stop sing-box service."

        # 2. Block ingress proxy port 443 via iptables as fail-safe
        iptables -A INPUT -p tcp --dport 443 -j DROP || log "WARNING: Failed to set iptables drop rule."

        # 3. Update block state
        sed -i 's/"is_blocked": "false"/"is_blocked": "true"/' "${STATE_FILE}"

        log "Circuit breaker triggered. Proxy service stopped and port 443 blocked."
    else
        log "Quota still exceeded. Service remains BLOCKED."
    fi
fi
