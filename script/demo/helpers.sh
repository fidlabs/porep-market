#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

EXPLORER_BASE="https://filecoin-testnet.blockscout.com"
STATE_FILE="script/demo/demo-state.json"

step_header() {
    local num="$1" total="$2" title="$3"
    echo ""
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  Step ${num}/${total}: ${title}${NC}"
    echo -e "${BOLD}${BLUE}════════════════════════════════════════════════════════════${NC}"
    echo ""
}

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

explorer_address() {
    local label="$1" address="$2"
    echo -e "${DIM}${label}:${NC} ${EXPLORER_BASE}/address/${address}"
}

save_state() {
    local key="$1" value="$2"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo '{}' > "$STATE_FILE"
    fi
    local tmp
    tmp=$(jq --arg k "$key" --arg v "$value" '.[$k] = $v' "$STATE_FILE")
    echo "$tmp" > "$STATE_FILE"
}

get_state() {
    local key="$1"
    if [[ ! -f "$STATE_FILE" ]]; then
        echo ""
        return
    fi
    jq -r --arg k "$key" '.[$k] // empty' "$STATE_FILE"
}

ensure_state() {
    local key="$1"
    local value
    value=$(get_state "$key")
    if [[ -z "$value" ]]; then
        error "Required state key '${key}' not found in ${STATE_FILE}"
        exit 1
    fi
    echo "$value"
}
