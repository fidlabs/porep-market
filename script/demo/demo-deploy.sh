#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# FEVM needs inflated gas estimates (can't simulate precompile costs locally).
# --slow avoids "too many pending messages" from Filecoin mempool.
FEVM_FLAGS="--gas-estimate-multiplier 100000 --disable-block-gas-limit --slow"

if [[ -z "${RPC_URL:-}" ]]; then
    error "RPC_URL is not set. Export it before running."
    exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
    error "PRIVATE_KEY is not set. Export it before running."
    exit 1
fi

info "Deploying all contracts to $(echo "$RPC_URL" | sed 's|https://||')..."
info "This takes 15+ minutes on Calibration (null rounds + --slow)."
echo ""

output=$(forge script script/demo/Demo.s.sol:DeployDemo --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)

sp_registry=$(echo "$output" | grep -a "DEPLOYED_SP_REGISTRY=" | sed 's/.*DEPLOYED_SP_REGISTRY=//' | tr -d '[:space:]')
sli_oracle=$(echo "$output" | grep -a "DEPLOYED_SLI_ORACLE=" | sed 's/.*DEPLOYED_SLI_ORACLE=//' | tr -d '[:space:]')
sli_scorer=$(echo "$output" | grep -a "DEPLOYED_SLI_SCORER=" | sed 's/.*DEPLOYED_SLI_SCORER=//' | tr -d '[:space:]')
porep_market=$(echo "$output" | grep -a "DEPLOYED_POREP_MARKET=" | sed 's/.*DEPLOYED_POREP_MARKET=//' | tr -d '[:space:]')
demo_helper=$(echo "$output" | grep -a "DEPLOYED_DEMO_HELPER=" | sed 's/.*DEPLOYED_DEMO_HELPER=//' | tr -d '[:space:]')

save_state "SP_REGISTRY" "$sp_registry"
save_state "SLI_ORACLE" "$sli_oracle"
save_state "SLI_SCORER" "$sli_scorer"
save_state "POREP_MARKET" "$porep_market"
save_state "DEMO_HELPER" "$demo_helper"

success "All contracts deployed"
echo ""
explorer_address "SPRegistry" "$sp_registry"
explorer_address "SLIOracle" "$sli_oracle"
explorer_address "SLIScorer" "$sli_scorer"
explorer_address "PoRepMarket" "$porep_market"
explorer_address "DemoHelper" "$demo_helper"
echo ""
success "State saved to ${STATE_FILE}. Run 'just demo' to start the demo."

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERIFY_SCRIPT="${REPO_ROOT}/script/verify-blockscout.sh"

if [[ -f "$VERIFY_SCRIPT" ]]; then
    echo ""
    info "Verifying contracts on Blockscout (this may take a minute)..."
    if bash "$VERIFY_SCRIPT" Calibnet; then
        success "All contracts verified on Blockscout."
    else
        warn "Some contracts failed verification. Run 'just verify-calibnet' to retry."
    fi
fi
