#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT/script/rescue-output"
MIN_CLAIM_WINDOW_EPOCHS=11520
MAX_CHAIN_EPOCH=9223372036854775807
ERC1967_IMPL_SLOT="0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc"
NETWORK="mainnet"
RESCUE_SIG='rescueDealAllocations(uint256,((bytes),(bytes,bool),bytes))'
MANIFEST=""
RPC=""
EXPECTED_CHAIN_ID=""

usage() {
  cat <<'EOF'
Usage:
  script/rescue-allocations.sh prepare --deal-ids IDS --term-min EPOCHS --term-max EPOCHS [--expiration EPOCHS] [--rescue-from ADDRESS] [--output PATH]
  script/rescue-allocations.sh execute --plan PATH [--dry-run|--broadcast]

Environment:
  RPC_MAINNET          Mainnet EVM RPC URL. Defaults to https://api.node.glif.io/rpc/v1.
  RESCUE_FROM          Optional rescue signer address for prepare-time RESCUE_ROLE check.
  ETH_FROM             Optional fallback rescue signer address for dry-runs.
  PRIVATE_KEY          Private key for execution, matching the repo deploy/upgrade convention.
  CONFIRM_MAINNET=yes EXECUTE_RESCUE=yes
                       Required only for execute --broadcast.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_chain_epoch_arg() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be a non-negative integer, got: ${value:-<empty>}"
  [[ "$value" == "0" || "$value" != 0* ]] || die "$name must be a canonical decimal integer, got: $value"
  if (( ${#value} > ${#MAX_CHAIN_EPOCH} )) || \
    { (( ${#value} == ${#MAX_CHAIN_EPOCH} )) && [[ "$value" > "$MAX_CHAIN_EPOCH" ]]; }; then
    die "$name must fit int64 Filecoin epoch range 0..$MAX_CHAIN_EPOCH, got: $value"
  fi
}

require_address_arg() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "$name must be an EVM address, got: $value"
}

require_arg_value() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || die "$flag requires a value"
}

configure_network() {
  EXPECTED_CHAIN_ID=314
  RPC="${RPC_MAINNET:-https://api.node.glif.io/rpc/v1}"
  [[ -n "$RPC" ]] || die "missing RPC for $NETWORK"
  MANIFEST="$ROOT/deployments/$NETWORK/latest.json"
}

json_rpc() {
  local payload="$1"
  local response normalized
  response="$(curl -fsS "$RPC" -H 'Content-Type: application/json' --data "$payload")" \
    || die "JSON-RPC request failed"
  normalized="$(jq -s '.[0]' <<<"$response")" || die "invalid JSON-RPC response"

  local error
  error="$(jq -r '.error // empty' <<<"$normalized")"
  [[ -z "$error" ]] || die "JSON-RPC error: $error"

  printf '%s\n' "$normalized"
}

chain_id() {
  cast chain-id --rpc-url "$RPC"
}

impl_slot() {
  cast storage "$1" "$ERC1967_IMPL_SLOT" --rpc-url "$RPC"
}

code_hash() {
  cast code "$1" --rpc-url "$RPC" | cast keccak
}

lower() {
  tr '[:upper:]' '[:lower:]'
}

normalize_slot_addr() {
  local value
  value="$(sed 's/^0x//' | tail -c 41)"
  printf '0x%s\n' "$value" | lower
}

manifest_address() {
  local path="$1"
  local value
  value="$(jq -er "$path" "$MANIFEST")" || die "missing manifest address at $path"
  [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || die "invalid manifest address at $path: $value"
  printf '%s\n' "$value"
}

manifest_hash() {
  local path="$1"
  local value
  value="$(jq -er "$path" "$MANIFEST")" || die "missing manifest hash at $path"
  [[ "$value" =~ ^0x[0-9a-fA-F]{64}$ ]] || die "invalid manifest hash at $path: $value"
  printf '%s\n' "$value" | lower
}

require_preflight() {
  require_cmd cast
  require_cmd curl
  require_cmd jq
  require_cmd python3
  [[ -f "$MANIFEST" ]] || die "missing manifest: $MANIFEST"

  local manifest_chain_id
  manifest_chain_id="$(jq -er '.chainId' "$MANIFEST")" || die "missing manifest chainId"
  [[ "$manifest_chain_id" == "$EXPECTED_CHAIN_ID" ]] \
    || die "manifest chainId is $manifest_chain_id, expected $EXPECTED_CHAIN_ID"

  local cid
  cid="$(chain_id)" || die "$NETWORK RPC is unreachable or cast chain-id failed"
  [[ "$cid" == "$EXPECTED_CHAIN_ID" ]] || die "expected chain $EXPECTED_CHAIN_ID, got $cid"

  local client_proxy client_impl market_proxy market_impl
  client_proxy="$(manifest_address '.Client.proxy')"
  client_impl="$(manifest_address '.Client.impl')"
  market_proxy="$(manifest_address '.PoRepMarket.proxy')"
  market_impl="$(manifest_address '.PoRepMarket.impl')"

  [[ "$(impl_slot "$client_proxy" | normalize_slot_addr)" == "$(printf '%s\n' "$client_impl" | lower)" ]] \
    || die "Client implementation slot mismatch"
  [[ "$(impl_slot "$market_proxy" | normalize_slot_addr)" == "$(printf '%s\n' "$market_impl" | lower)" ]] \
    || die "PoRepMarket implementation slot mismatch"
  [[ "$(code_hash "$client_impl" | lower)" == "$(manifest_hash '.Client.codeHash')" ]] \
    || die "Client code hash mismatch"
  [[ "$(code_hash "$market_impl" | lower)" == "$(manifest_hash '.PoRepMarket.codeHash')" ]] \
    || die "PoRepMarket code hash mismatch"
}

prepare() {
  local term_min="" term_max="" expiration="" output="$OUT_DIR/mainnet-allocation-rescue-plan.json"
  local rescue_from=""
  local deal_ids=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --deal-ids)
        require_arg_value "$1" "${2:-}"
        deal_ids="$2"
        shift 2
        ;;
      --term-min)
        require_arg_value "$1" "${2:-}"
        term_min="$2"
        shift 2
        ;;
      --term-max)
        require_arg_value "$1" "${2:-}"
        term_max="$2"
        shift 2
        ;;
      --expiration)
        require_arg_value "$1" "${2:-}"
        expiration="$2"
        shift 2
        ;;
      --rescue-from)
        require_arg_value "$1" "${2:-}"
        rescue_from="$2"
        shift 2
        ;;
      --output)
        require_arg_value "$1" "${2:-}"
        output="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown prepare arg: $1"
        ;;
    esac
  done

  [[ -n "$term_min" ]] || die "--term-min is required"
  [[ -n "$term_max" ]] || die "--term-max is required"
  [[ -n "$deal_ids" ]] || die "prepare requires --deal-ids IDS"
  require_chain_epoch_arg "--term-min" "$term_min"
  require_chain_epoch_arg "--term-max" "$term_max"
  [[ -z "$expiration" ]] || require_chain_epoch_arg "--expiration" "$expiration"
  (( term_max >= term_min )) || die "--term-max must be greater than or equal to --term-min"
  (( term_max - term_min >= MIN_CLAIM_WINDOW_EPOCHS )) \
    || die "term window must be at least $MIN_CLAIM_WINDOW_EPOCHS epochs"

  if [[ -z "$rescue_from" && -n "${RESCUE_FROM:-}" ]]; then
    rescue_from="$RESCUE_FROM"
  fi
  if [[ -n "$rescue_from" ]]; then
    require_address_arg "rescue signer" "$rescue_from"
  fi

  require_preflight
  mkdir -p "$(dirname "$output")"

  local client_proxy market_proxy client_fil client_id head
  client_proxy="$(manifest_address '.Client.proxy')"
  market_proxy="$(manifest_address '.PoRepMarket.proxy')"
  client_fil="$(
    json_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Filecoin.EthAddressToFilecoinAddress\",\"params\":[\"$client_proxy\"]}" \
      | jq -er '.result'
  )" || die "failed to resolve Client proxy Filecoin address"
  client_id="$(
    json_rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Filecoin.StateLookupID\",\"params\":[\"$client_fil\",[]]}" \
      | jq -er '.result' \
      | sed -E 's/^[ft]0//'
  )" || die "failed to resolve Client actor ID"
  head="$(
    json_rpc '{"jsonrpc":"2.0","id":1,"method":"Filecoin.ChainHead","params":[]}' \
      | jq -er '.result.Height'
  )" || die "failed to read chain head"
  [[ "$head" =~ ^[0-9]+$ ]] || die "chain head must be a non-negative integer, got: ${head:-<empty>}"
  [[ -n "$expiration" ]] || expiration=$((head + 120960))

  local parser="$ROOT/script/rescue-allocations-parse.py"
  [[ -x "$parser" || -f "$parser" ]] \
    || die "missing parser: $parser"

  local parser_args=(
    "$parser"
    --rpc "$RPC"
    --expected-chain-id "$EXPECTED_CHAIN_ID"
    --client "$client_proxy"
    --market "$market_proxy"
    --client-fil "$client_fil"
    --client-id "$client_id"
    --term-min "$term_min"
    --term-max "$term_max"
    --expiration "$expiration"
    --output "$output"
  )
  parser_args+=(--deal-ids "$deal_ids")
  if [[ -n "$rescue_from" ]]; then
    parser_args+=(--rescue-signer "$rescue_from")
  fi

  python3 "${parser_args[@]}"

  echo "Wrote rescue plan: $output"
}

load_plan() {
  local plan="$1"
  [[ -n "$plan" ]] || die "--plan is required"
  [[ -f "$plan" ]] || die "missing plan: $plan"
  jq -e '.chainId and .clientProxy and .deals and (.deals | type == "array")' "$plan" >/dev/null \
    || die "invalid rescue plan: $plan"
}

require_plan_preflight() {
  local plan="$1"
  require_preflight

  local plan_chain client manifest_client min_window
  plan_chain="$(jq -er '.chainId' "$plan")" || die "plan is missing chainId"
  [[ "$plan_chain" == "$EXPECTED_CHAIN_ID" ]] || die "plan chain mismatch: plan=$plan_chain expected=$EXPECTED_CHAIN_ID"

  client="$(jq -er '.clientProxy' "$plan")" || die "plan is missing clientProxy"
  manifest_client="$(manifest_address '.Client.proxy')"
  [[ "$(printf '%s\n' "$client" | lower)" == "$(printf '%s\n' "$manifest_client" | lower)" ]] \
    || die "plan clientProxy does not match $NETWORK manifest"

  min_window="$(jq -er '.minClaimWindowEpochs' "$plan")" || die "plan is missing minClaimWindowEpochs"
  [[ "$min_window" == "$MIN_CLAIM_WINDOW_EPOCHS" ]] \
    || die "plan minClaimWindowEpochs is $min_window, expected $MIN_CLAIM_WINDOW_EPOCHS"
}

plan_rescue_sender() {
  local plan="$1"
  local sender="${RESCUE_FROM:-${ETH_FROM:-}}"
  if [[ -z "$sender" ]]; then
    sender="$(jq -r '.rescueSigner // empty' "$plan")"
  fi
  [[ -n "$sender" ]] || die "set RESCUE_FROM/ETH_FROM or prepare the plan with --rescue-from"
  require_address_arg "rescue signer" "$sender"
  printf '%s\n' "$sender"
}

require_execute_role_plan() {
  local plan="$1" sender="$2"
  local plan_sender role_granted
  plan_sender="$(jq -r '.rescueSigner // empty' "$plan")"
  [[ -n "$plan_sender" ]] \
    || die "plan has no rescueSigner; rerun prepare with --rescue-from or RESCUE_FROM before execute"
  [[ "$(printf '%s\n' "$plan_sender" | lower)" == "$(printf '%s\n' "$sender" | lower)" ]] \
    || die "plan rescueSigner does not match execution signer"
  role_granted="$(jq -r '.rescueRoleGranted // empty' "$plan")"
  [[ "$role_granted" == "true" ]] \
    || die "plan does not confirm RESCUE_ROLE for the execution signer"
}

deal_transfer_tuple() {
  local plan="$1" deal_index="$2"
  jq -er ".deals[$deal_index].transferParams.castTuple" "$plan"
}

simulate_plan() {
  local plan="$1"
  load_plan "$plan"
  require_plan_preflight "$plan"

  local client deals_len sender
  client="$(jq -er '.clientProxy' "$plan")"
  deals_len="$(jq -er '.deals | length' "$plan")"

  if (( deals_len == 0 )); then
    echo "No rescue deals in plan"
    return 0
  fi

  sender="$(plan_rescue_sender "$plan")"

  for i in $(seq 0 $((deals_len - 1))); do
    local deal_id params rescue_count
    deal_id="$(jq -er ".deals[$i].dealId" "$plan")"
    rescue_count="$(jq -er ".deals[$i].rescueCount" "$plan")"
    params="$(deal_transfer_tuple "$plan" "$i")"
    echo "Dry-running deal $deal_id ($rescue_count allocations)"
    cast call "$client" "$RESCUE_SIG" "$deal_id" "$params" --from "$sender" --rpc-url "$RPC" >/dev/null
  done
}

print_send_commands() {
  local plan="$1" sender="$2"
  local client deals_len
  client="$(jq -er '.clientProxy' "$plan")"
  deals_len="$(jq -er '.deals | length' "$plan")"
  if (( deals_len == 0 )); then
    return 0
  fi

  for i in $(seq 0 $((deals_len - 1))); do
    local deal_id params
    deal_id="$(jq -er ".deals[$i].dealId" "$plan")"
    params="$(deal_transfer_tuple "$plan" "$i")"
    printf 'cast send %q %q %q %q --from %q --rpc-url %q\n' \
      "$client" "$RESCUE_SIG" "$deal_id" "$params" "$sender" "$RPC"
  done
}

execute() {
  local plan="" mode="dry-run"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan)
        require_arg_value "$1" "${2:-}"
        plan="$2"
        shift 2
        ;;
      --dry-run)
        mode="dry-run"
        shift
        ;;
      --broadcast)
        mode="broadcast"
        shift
        ;;
      -h|--help)
        echo "usage: script/rescue-allocations.sh execute --plan PATH [--dry-run|--broadcast]"
        exit 0
        ;;
      *)
        die "unknown execute arg: $1"
        ;;
    esac
  done

  load_plan "$plan"
  local deals_len sender
  deals_len="$(jq -er '.deals | length' "$plan")"
  if (( deals_len == 0 )); then
    simulate_plan "$plan"
    return 0
  fi

  sender="$(plan_rescue_sender "$plan")"
  require_execute_role_plan "$plan" "$sender"
  simulate_plan "$plan"

  if [[ "$mode" == "dry-run" ]]; then
    echo
    echo "Dry-run passed. Broadcast commands:"
    print_send_commands "$plan" "$sender"
    return 0
  fi

  [[ "${CONFIRM_MAINNET:-}" == "yes" ]] || die "set CONFIRM_MAINNET=yes"
  [[ "${EXECUTE_RESCUE:-}" == "yes" ]] || die "set EXECUTE_RESCUE=yes"
  [[ -n "${PRIVATE_KEY:-}" ]] || die "configure PRIVATE_KEY for execute"

  local client report tmp
  client="$(jq -er '.clientProxy' "$plan")"
  report="${plan%.json}.execution.json"
  tmp="$(mktemp)"
  jq -n --arg plan "$plan" --arg sender "$sender" \
    '{plan:$plan, sender:$sender, transactions:[]}' >"$tmp"
  mv "$tmp" "$report"

  for i in $(seq 0 $((deals_len - 1))); do
    local deal_id params tx_hash
    deal_id="$(jq -er ".deals[$i].dealId" "$plan")"
    params="$(deal_transfer_tuple "$plan" "$i")"
    echo "Dry-running deal $deal_id before broadcast"
    cast call "$client" "$RESCUE_SIG" "$deal_id" "$params" --from "$sender" --rpc-url "$RPC" >/dev/null
    echo "Broadcasting deal $deal_id"
    tx_hash="$(cast send "$client" "$RESCUE_SIG" "$deal_id" "$params" \
      --from "$sender" \
      --private-key "$PRIVATE_KEY" \
      --rpc-url "$RPC" \
      --json | jq -er '.transactionHash')"
    tmp="$(mktemp)"
    jq --argjson dealId "$deal_id" --arg txHash "$tx_hash" \
      '.transactions += [{dealId:$dealId, txHash:$txHash}]' "$report" >"$tmp"
    mv "$tmp" "$report"
  done
  echo "Wrote execution report: $report"
}

main() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 1; }
  configure_network
  shift
  case "$cmd" in
    prepare) prepare "$@" ;;
    execute) execute "$@" ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
