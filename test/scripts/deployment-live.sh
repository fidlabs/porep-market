#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; tmp="$(mktemp -d)"; trap 'rm -r "$tmp"' EXIT
addr=0x$(printf '1%.0s' {1..40}); filecoin_pay=0x$(printf '2%.0s' {1..40}); meta_allocator=0x$(printf '3%.0s' {1..40}); zero=0x$(printf '0%.0s' {1..40})
jq -n --arg a "$addr" --arg f "$filecoin_pay" --arg m "$meta_allocator" --arg z "$zero" '{deployer:$a,contracts:{PoRepMarket:{proxy:$a,implementation:$a},ValidatorFactory:{proxy:$a,implementation:$a},DataCapEvidenceAdapter:{proxy:$a,implementation:$a},SPRegistry:{proxy:$a,implementation:$a},SLIOracle:{proxy:$a,implementation:$a},SLIScorer:{proxy:$a,implementation:$a},Validator:{implementation:$a},ValidatorBeacon:{address:$a}},externalDependencies:{FilecoinPay:$f,MetaAllocator:$m,PoRepService:$a,Oracle:$a,TerminationOracle:$a,Operator:$z}}' >"$tmp/manifest.json"
cat >"$tmp/cast" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *codehash*) exit 2 ;;
  *keccak*) [[ "${EMPTY_RUNTIME:-}" == 1 ]] && printf '%s\n' '0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470' || printf '0x%s\n' "$(printf '1%.0s' {1..64})" ;;
  *eth_getCode*)
    address="${@: -2:1}"
    [[ "${EMPTY_RUNTIME:-}" == 1 || "${EMPTY_RUNTIME_ADDRESS:-}" == "$address" ]] && printf '"0x"\n' || printf '"0x01"\n'
    ;;
  *eth_getStorageAt*) printf '"0x0000000000000000000000001111111111111111111111111111111111111111"\n' ;;
  *hasRole*) printf 'true\n' ;;
  *DEFAULT_ADMIN_ROLE*|*POREP_SERVICE_ROLE*|*ORACLE_ROLE*|*TERMINATION_ORACLE*|*MARKET_ROLE*|*OPERATOR_ROLE*) printf '0x%s\n' "$(printf '0%.0s' {1..64})" ;;
  *) printf '0x0000000000000000000000001111111111111111111111111111111111111111\n' ;;
esac
EOF
chmod +x "$tmp/cast"
jq -n --arg a "$addr" --arg h "0x$(printf '1%.0s' {1..64})" '[{target:"PoRepMarket",kind:"uups",newImplementation:$a,newImplementationCodeHash:$h},{target:"Validator",kind:"beacon",newImplementation:$a,newImplementationCodeHash:$h}]' >"$tmp/operations.json"
CAST_BIN="$tmp/cast" "$ROOT/script/deployment-live-checks.sh" --manifest "$tmp/manifest.json" --operations "$tmp/operations.json" --rpc-url rpc
empty_hash=0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
jq -n --arg a "$addr" --arg h "$empty_hash" '[{target:"PoRepMarket",kind:"uups",newImplementation:$a,newImplementationCodeHash:$h},{target:"Validator",kind:"beacon",newImplementation:$a,newImplementationCodeHash:$h}]' >"$tmp/empty-operations.json"
if EMPTY_RUNTIME=1 CAST_BIN="$tmp/cast" "$ROOT/script/deployment-live-checks.sh" --manifest "$tmp/manifest.json" --operations "$tmp/empty-operations.json" --rpc-url rpc 2>/dev/null; then printf 'FAIL: empty runtime bytecode accepted\n'; exit 1; fi
for dependency in FilecoinPay MetaAllocator; do
  address="$(jq -r ".externalDependencies.$dependency" "$tmp/manifest.json")"
  if EMPTY_RUNTIME_ADDRESS="$address" CAST_BIN="$tmp/cast" "$ROOT/script/deployment-live-checks.sh" --manifest "$tmp/manifest.json" --rpc-url rpc 2>/dev/null; then
    printf 'FAIL: %s without runtime bytecode accepted\n' "$dependency"; exit 1
  fi
done
jq '.contracts.PoRepMarket.implementation="0x2222222222222222222222222222222222222222"' "$tmp/manifest.json" >"$tmp/bad.json"
if CAST_BIN="$tmp/cast" "$ROOT/script/deployment-live-checks.sh" --manifest "$tmp/bad.json" --rpc-url rpc 2>/dev/null; then exit 1; fi
printf 'deployment live topology: PASS\n'
