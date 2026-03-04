#!/usr/bin/env bash
set -euo pipefail

# Verify deployed contracts on Blockscout via forge verify-contract.
# Reads contract list from Foundry broadcast JSON and submits each
# implementation contract for verification.
#
# Usage:
#   ./script/verify-blockscout.sh [Calibnet|Mainnet] [broadcast-json-path]
#
# Examples:
#   ./script/verify-blockscout.sh Calibnet
#   ./script/verify-blockscout.sh Calibnet broadcast/Demo.s.sol/314159/run-latest.json

NETWORK="${1:-Calibnet}"

case "$NETWORK" in
  Calibnet)
    CHAIN_ID="314159"
    BLOCKSCOUT_URL="https://filecoin-testnet.blockscout.com/api/"
    EXPLORER_URL="https://filecoin-testnet.blockscout.com/address"
    ;;
  Mainnet)
    CHAIN_ID="314"
    BLOCKSCOUT_URL="https://filecoin.blockscout.com/api/"
    EXPLORER_URL="https://filecoin.blockscout.com/address"
    ;;
  *)
    echo "Unknown network: $NETWORK (use Calibnet or Mainnet)"
    exit 1
    ;;
esac

if [[ -n "${2:-}" ]]; then
  DEPLOY_JSON="$2"
else
  # run-latest.json may be overwritten by subsequent script runs (e.g. demo steps).
  # Find the most recent broadcast that actually contains CREATE transactions.
  DEPLOY_JSON=""
  while IFS= read -r candidate; do
    if python3 -c "
import json, sys
data = json.load(open('$candidate'))
has_create = any(tx.get('transactionType') == 'CREATE' for tx in data['transactions'])
sys.exit(0 if has_create else 1)
" 2>/dev/null; then
      DEPLOY_JSON="$candidate"
      break
    fi
  done < <(find broadcast -path "*/${CHAIN_ID}/run-*.json" -not -name "run-latest.json" -type f 2>/dev/null | sort -r)
fi

if [[ -z "$DEPLOY_JSON" || ! -f "$DEPLOY_JSON" ]]; then
  echo "No deployment broadcast found. Provide path as second argument."
  echo "  e.g.: $0 $NETWORK broadcast/Demo.s.sol/${CHAIN_ID}/run-latest.json"
  exit 1
fi

echo "Network:    $NETWORK (chain $CHAIN_ID)"
echo "Broadcast:  $DEPLOY_JSON"
echo "Blockscout: $BLOCKSCOUT_URL"
echo ""

# ── Extract contracts from broadcast ────────────────────────────────

CONTRACTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && CONTRACTS+=("$line")
done < <(
  python3 -c "
import json
data = json.load(open('$DEPLOY_JSON'))
seen = set()
for tx in data['transactions']:
    name = tx.get('contractName')
    addr = tx.get('contractAddress')
    typ  = tx.get('transactionType')
    if name and addr and typ == 'CREATE' and name not in seen:
        seen.add(name)
        print(f'{name}|{addr}')
" 2>/dev/null
)

if [[ ${#CONTRACTS[@]} -eq 0 ]]; then
  echo "No deployed contracts found in $DEPLOY_JSON"
  exit 0
fi

echo "Found ${#CONTRACTS[@]} contracts to verify:"
for entry in "${CONTRACTS[@]}"; do
  IFS='|' read -r NAME ADDR <<< "$entry"
  echo "  $NAME @ $ADDR"
done
echo ""

# ── Verify each contract ────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0

for entry in "${CONTRACTS[@]}"; do
  IFS='|' read -r NAME ADDR <<< "$entry"
  echo "── $NAME @ $ADDR ──────────────────────────────"

  # Locate source file
  SRC_PATH=$(find src script -type f -name "${NAME}.sol" -print -quit 2>/dev/null || true)
  if [[ -z "$SRC_PATH" ]]; then
    echo "  Source not in src/ or script/, skipping."
    echo ""
    SKIP=$((SKIP + 1))
    continue
  fi
  echo "  Source: $SRC_PATH"

  # Submit via forge verify-contract
  echo "  Submitting to Blockscout..."
  OUTPUT=$(forge verify-contract \
    "$ADDR" \
    "${SRC_PATH}:${NAME}" \
    --verifier blockscout \
    --verifier-url "$BLOCKSCOUT_URL" \
    --chain "$CHAIN_ID" \
    2>&1) || true

  if echo "$OUTPUT" | grep -q "already verified"; then
    echo "  Already verified."
    echo "  $EXPLORER_URL/$ADDR"
    PASS=$((PASS + 1))
  elif echo "$OUTPUT" | grep -q "successfully verified\|Pass - Verified"; then
    echo "  Verified."
    echo "  $EXPLORER_URL/$ADDR"
    PASS=$((PASS + 1))
  else
    echo "  Failed: $OUTPUT"
    FAIL=$((FAIL + 1))
  fi

  echo ""
done

echo "════════════════════════════════════════════════════"
echo "Results: $PASS verified, $FAIL failed, $SKIP skipped"
echo "════════════════════════════════════════════════════"

[[ $FAIL -eq 0 ]]
