#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

TOTAL_STEPS=6

# FEVM needs inflated gas estimates (can't simulate precompile costs locally).
# --slow avoids "too many pending messages" from Filecoin mempool.
FEVM_FLAGS="--gas-estimate-multiplier 100000 --disable-block-gas-limit --slow"

if [[ -z "${RPC_URL:-}" ]]; then
    error "RPC_URL is not set. Export it before running the demo."
    exit 1
fi

if [[ -z "${PRIVATE_KEY:-}" ]]; then
    error "PRIVATE_KEY is not set. Export it before running the demo."
    exit 1
fi

sp_registry=$(ensure_state "SP_REGISTRY")
sli_oracle=$(ensure_state "SLI_ORACLE")
sli_scorer=$(ensure_state "SLI_SCORER")
porep_market=$(ensure_state "POREP_MARKET")
demo_helper=$(ensure_state "DEMO_HELPER")

echo ""
echo -e "${BOLD}Deployed Contracts${NC}"
echo ""
explorer_address "SPRegistry" "$sp_registry"
explorer_address "SLIOracle" "$sli_oracle"
explorer_address "SLIScorer" "$sli_scorer"
explorer_address "PoRepMarket" "$porep_market"
explorer_address "DemoHelper" "$demo_helper"

# Step 1: Setup Marketplace

step_header 1 $TOTAL_STEPS "Setup Marketplace"

info "Registering SP Alpha: Actor 1001 | 100 TiB | retrievability=95%, bandwidth=500Mbps, latency=50ms, indexing=90% | floor=0.5 FIL"
info "Registering SP Beta:  Actor 1002 |  50 TiB | retrievability=70%, bandwidth=100Mbps, latency=200ms, indexing=60% | floor=0.3 FIL"
info "Setting SLI attestations for both providers"

output=$(SP_REGISTRY="$sp_registry" SLI_ORACLE="$sli_oracle" forge script script/demo/Demo.s.sol:SetupMarketplace --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)

success "SP Alpha registered"
success "SP Beta registered"
success "SLI attestations submitted for both providers"

# Step 2: Score Comparison & Propose Deal #1

step_header 2 $TOTAL_STEPS "Score Comparison & Propose Deal #1"

info "Requirements: retrievability>=90%, bandwidth>=400Mbps, latency<=100ms, indexing>=80%"
info "32 GiB deal, price 0.4 FIL/sector (below Alpha's floor of 0.5 -- no auto-approve)"

score_output_file=$(mktemp)
(SLI_SCORER="$sli_scorer" forge script script/demo/Demo.s.sol:CompareScores --rpc-url "$RPC_URL" -vvv 2>&1 > "$score_output_file") &
score_pid=$!

deal_output=$(POREP_MARKET="$porep_market" forge script script/demo/Demo.s.sol:ProposeDealHigh --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)

wait "$score_pid" || true
score_output=$(cat "$score_output_file")
rm -f "$score_output_file"

score_alpha=$(echo "$score_output" | grep -a "SCORE_ALPHA=" | sed 's/.*SCORE_ALPHA=//' | tr -d '[:space:]')
score_beta=$(echo "$score_output" | grep -a "SCORE_BETA=" | sed 's/.*SCORE_BETA=//' | tr -d '[:space:]')

echo ""
echo -e "  ${BOLD}SLI Scores${NC}"
echo -e "  SP Alpha:  ${GREEN}${score_alpha}/100${NC}  Meets all thresholds"
echo -e "  SP Beta:   ${RED}${score_beta}/100${NC}  Below requirements"
echo ""

deal_1_id=$(echo "$deal_output" | grep -a "DEAL_1_ID=" | sed 's/.*DEAL_1_ID=//' | tr -d '[:space:]')
deal_1_provider=$(echo "$deal_output" | grep -a "DEAL_1_PROVIDER=" | sed 's/.*DEAL_1_PROVIDER=//' | tr -d '[:space:]')
deal_1_state=$(echo "$deal_output" | grep -a "DEAL_1_STATE=" | sed 's/.*DEAL_1_STATE=//' | tr -d '[:space:]')

save_state "DEAL_1_ID" "$deal_1_id"

success "Deal #1 proposed"
info "Selected provider: ${deal_1_provider} (SP Alpha)"
info "Deal state: Proposed (${deal_1_state})"
info "SP Beta was skipped -- does not meet quality thresholds"

# Step 3: Reject Deal #1

step_header 3 $TOTAL_STEPS "Reject Deal #1"

info "Demonstrating the unhappy path: SP rejects the deal"

output=$(POREP_MARKET="$porep_market" SP_REGISTRY="$sp_registry" forge script script/demo/Demo.s.sol:RejectDeal --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)

deal_1_state=$(echo "$output" | grep -a "DEAL_1_STATE=" | sed 's/.*DEAL_1_STATE=//' | tr -d '[:space:]')
alpha_pending=$(echo "$output" | grep -a "ALPHA_PENDING_AFTER=" | sed 's/.*ALPHA_PENDING_AFTER=//' | tr -d '[:space:]')
alpha_available=$(echo "$output" | grep -a "ALPHA_AVAILABLE=" | sed 's/.*ALPHA_AVAILABLE=//' | tr -d '[:space:]')

success "Deal #1 rejected"
echo ""
info "Deal state: Rejected (${deal_1_state})"
info "Alpha pending bytes: ${alpha_pending} (released back to 0)"
info "Alpha available bytes: ${alpha_available} (restored)"

# Step 4: Propose Deal #2 (Auto-Approve)

step_header 4 $TOTAL_STEPS "Propose Deal #2 (Auto-Approve)"

info "Relaxed requirements, price meets SP floor (0.5 FIL >= Alpha's 0.5 FIL floor)"

output=$(POREP_MARKET="$porep_market" forge script script/demo/Demo.s.sol:ProposeDealAutoApprove --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)

deal_2_id=$(echo "$output" | grep -a "DEAL_2_ID=" | sed 's/.*DEAL_2_ID=//' | tr -d '[:space:]')
deal_2_state=$(echo "$output" | grep -a "DEAL_2_STATE=" | sed 's/.*DEAL_2_STATE=//' | tr -d '[:space:]')

save_state "DEAL_2_ID" "$deal_2_id"

if [[ "$deal_2_state" == "1" ]]; then
    success "Deal #2 proposed and auto-approved!"
    info "Deal state: Accepted (1)"
else
    warn "Auto-approve did not trigger (state=${deal_2_state}). Running fallback accept..."
    output=$(POREP_MARKET="$porep_market" forge script script/demo/Demo.s.sol:AcceptDealFallback --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)
    success "Deal #2 accepted via fallback"
    info "Deal state: Accepted (1)"
fi

# Step 5: Complete Deal #2

step_header 5 $TOTAL_STEPS "Complete Deal #2"

info "Marking deal as completed"

output=$(DEMO_HELPER="$demo_helper" POREP_MARKET="$porep_market" SP_REGISTRY="$sp_registry" forge script script/demo/Demo.s.sol:CompleteDeal --rpc-url "$RPC_URL" --broadcast $FEVM_FLAGS -vvv 2>&1)

deal_2_state=$(echo "$output" | grep -a "DEAL_2_STATE=" | sed 's/.*DEAL_2_STATE=//' | tr -d '[:space:]')
provider_committed=$(echo "$output" | grep -a "PROVIDER_COMMITTED=" | sed 's/.*PROVIDER_COMMITTED=//' | tr -d '[:space:]')
provider_pending=$(echo "$output" | grep -a "PROVIDER_PENDING=" | sed 's/.*PROVIDER_PENDING=//' | tr -d '[:space:]')
provider_id=$(echo "$output" | grep -a "PROVIDER_ID=" | sed 's/.*PROVIDER_ID=//' | tr -d '[:space:]')

success "Deal #2 completed"
echo ""
info "Deal state: Completed (${deal_2_state})"
info "Provider ${provider_id} committed: ${provider_committed} bytes"
info "Provider ${provider_id} pending: ${provider_pending} bytes"

# Step 6: Summary

step_header 6 $TOTAL_STEPS "Summary"

echo -e "${BOLD}Deployed Contracts${NC}"
echo ""
explorer_address "SPRegistry" "$sp_registry"
explorer_address "SLIOracle" "$sli_oracle"
explorer_address "SLIScorer" "$sli_scorer"
explorer_address "PoRepMarket" "$porep_market"
explorer_address "DemoHelper" "$demo_helper"
echo ""

output=$(POREP_MARKET="$porep_market" SP_REGISTRY="$sp_registry" SLI_SCORER="$sli_scorer" SLI_ORACLE="$sli_oracle" forge script script/demo/Demo.s.sol:DemoSummary --rpc-url "$RPC_URL" -vvv 2>&1)

state_names=("Proposed" "Accepted" "Completed" "Rejected")

deal_1_final=$(echo "$output" | grep -a "SUMMARY_DEAL_1_STATE=" | sed 's/.*SUMMARY_DEAL_1_STATE=//' | tr -d '[:space:]')
deal_2_final=$(echo "$output" | grep -a "SUMMARY_DEAL_2_STATE=" | sed 's/.*SUMMARY_DEAL_2_STATE=//' | tr -d '[:space:]')

echo -e "${BOLD}Deal States${NC}"
echo -e "  Deal #1: ${state_names[$deal_1_final]} (${deal_1_final})"
echo -e "  Deal #2: ${state_names[$deal_2_final]} (${deal_2_final})"
echo ""

alpha_avail=$(echo "$output" | grep -a "ALPHA_AVAILABLE=" | sed 's/.*ALPHA_AVAILABLE=//' | tr -d '[:space:]')
alpha_commit=$(echo "$output" | grep -a "ALPHA_COMMITTED=" | sed 's/.*ALPHA_COMMITTED=//' | tr -d '[:space:]')
alpha_pend=$(echo "$output" | grep -a "ALPHA_PENDING=" | sed 's/.*ALPHA_PENDING=//' | tr -d '[:space:]')
beta_avail=$(echo "$output" | grep -a "BETA_AVAILABLE=" | sed 's/.*BETA_AVAILABLE=//' | tr -d '[:space:]')
beta_commit=$(echo "$output" | grep -a "BETA_COMMITTED=" | sed 's/.*BETA_COMMITTED=//' | tr -d '[:space:]')
beta_pend=$(echo "$output" | grep -a "BETA_PENDING=" | sed 's/.*BETA_PENDING=//' | tr -d '[:space:]')

echo -e "${BOLD}Provider Capacity${NC}"
echo -e "  SP Alpha (1001): available=${alpha_avail} committed=${alpha_commit} pending=${alpha_pend}"
echo -e "  SP Beta  (1002): available=${beta_avail} committed=${beta_commit} pending=${beta_pend}"
echo ""

alpha_score=$(echo "$output" | grep -a "ALPHA_SCORE=" | sed 's/.*ALPHA_SCORE=//' | tr -d '[:space:]')
beta_score=$(echo "$output" | grep -a "BETA_SCORE=" | sed 's/.*BETA_SCORE=//' | tr -d '[:space:]')

echo -e "${BOLD}SLI Scores${NC}"
echo -e "  SP Alpha: ${alpha_score}/100"
echo -e "  SP Beta:  ${beta_score}/100"
echo ""

echo -e "${BOLD}${GREEN}Demo complete.${NC}"
