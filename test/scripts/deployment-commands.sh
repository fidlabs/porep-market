#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/script/deployment.sh"
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for portable_script in deployment.sh deployment-live-checks.sh verify-filecoin-finality.sh; do
  if grep -Eq '\$\{[^}]+(,,|\^\^)\}' "$ROOT/script/$portable_script"; then
    fail "$portable_script uses Bash-4-only case conversion"
  fi
done

cat >"$tmp/cast" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == chain-id ]] || exit 2
printf '%s\n' "${TEST_CHAIN_ID:-314}"
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != -C ]] || shift 2
case "${1:-}" in
  rev-parse) printf '%s\n' 1111111111111111111111111111111111111111 ;;
  status) [[ "${TEST_GIT_DIRTY:-0}" == 0 ]] || printf '%s\n' ' M src/PoRepMarket.sol' ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/forge" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FORGE_LOG"
exit "${FORGE_EXIT:-99}"
EOF
chmod +x "$tmp/cast" "$tmp/git" "$tmp/forge"

export DEPLOYMENTS_ROOT="$tmp/deployments"
export PENDING_ROOT="$tmp/pending"
export CAST_BIN="$tmp/cast"
export GIT_BIN="$tmp/git"
export FORGE_BIN="$tmp/forge"
export FORGE_LOG="$tmp/forge.log"
export RPC_MAINNET=rpc
export PRIVATE_KEY_MAINNET=key
export FILECOIN_PAY_MAINNET=0x1
export TERMINATION_ORACLE_MAINNET=0x2
export ORACLE_MAINNET=0x3
export POREP_SERVICE_MAINNET=0x4
export META_ALLOCATOR_MAINNET=0x5
export OPERATOR_ADDR_MAINNET=0x6

if "$SCRIPT" deploy mainnet --fresh 2>"$tmp/error"; then fail 'mainnet --fresh succeeded'; fi
grep -q 'fresh mainnet deployment is not supported' "$tmp/error" || fail 'mainnet rejection was unclear'

mkdir -p "$DEPLOYMENTS_ROOT/calibnet"
printf '{}\n' >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
if "$SCRIPT" upgrade calibnet 2>"$tmp/error"; then fail 'missing targets succeeded'; fi
grep -q 'at least one upgrade target is required' "$tmp/error" || fail 'missing-target rejection was unclear'
if "$SCRIPT" upgrade calibnet PoRepMarket PoRepMarket 2>"$tmp/error"; then fail 'duplicate targets succeeded'; fi
grep -q 'duplicate upgrade target: PoRepMarket' "$tmp/error" || fail 'duplicate-target rejection was unclear'
if "$SCRIPT" upgrade calibnet PoRepMarket Unknown 2>"$tmp/error"; then fail 'unknown target succeeded'; fi
grep -q 'unsupported upgrade target: Unknown' "$tmp/error" || fail 'unknown-target rejection was unclear'
if "$SCRIPT" upgrade calibnet Unknown 2>"$tmp/error"; then fail 'unknown target succeeded'; fi
grep -q 'unsupported upgrade target' "$tmp/error" || fail 'unknown target rejection was unclear'

: >"$FORGE_LOG"
if CONFIRM_MAINNET= "$SCRIPT" deploy mainnet 2>"$tmp/error"; then fail 'mainnet deploy accepted missing confirmation'; fi
grep -q 'CONFIRM_MAINNET=yes' "$tmp/error" || fail 'missing confirmation rejection was unclear'
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran before confirmation check'

: >"$FORGE_LOG"
if TEST_CHAIN_ID=314159 CONFIRM_MAINNET=yes "$SCRIPT" deploy mainnet 2>"$tmp/error"; then
  fail 'mainnet deploy accepted chain 314159'
fi
grep -q 'expected chain 314' "$tmp/error" || fail 'wrong-chain rejection was unclear'
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran before chain check'

: >"$FORGE_LOG"
if TEST_GIT_DIRTY=1 CONFIRM_MAINNET=yes "$SCRIPT" deploy mainnet 2>"$tmp/error"; then
  fail 'mainnet deploy accepted dirty deployment source'
fi
grep -q 'tracked deployment source is dirty' "$tmp/error" || fail 'dirty-source rejection was unclear'
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran before clean-source check'

printf '{"contracts":{}}\n' >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
names=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator)
for index in "${!names[@]}"; do
  name="${names[$index]}"; digit=$(( index + 1 ))
  address="0x$(printf '%040d' 0 | tr 0 "$digit")"
  artifact="src/$name.sol:$name"
  jq --arg name "$name" --arg address "$address" --arg artifact "$artifact" \
    '.contracts[$name]={implementation:$address,artifact:$artifact}' \
    "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
  mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
done
jq --arg address "0x$(printf '8%.0s' {1..40})" \
  '.contracts.ValidatorBeacon={address:$address,implementation:$address,
    artifact:"lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon"}' \
  "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
export RPC_CALIBNET=rpc
: >"$FORGE_LOG"
FORGE_EXIT=0 "$SCRIPT" verify calibnet
[[ "$(wc -l <"$FORGE_LOG" | tr -d ' ')" == 7 ]] || fail 'verification did not make exactly seven submissions'
for index in "${!names[@]}"; do
  name="${names[$index]}"; digit=$(( index + 1 ))
  address="0x$(printf '%040d' 0 | tr 0 "$digit")"
  grep -q "verify-contract $address src/$name.sol:$name .* --watch" "$FORGE_LOG" \
    || fail "$name implementation was not verified with --watch"
done
grep -q -- '--verifier-url https://filecoin-testnet.blockscout.com/api/' "$FORGE_LOG" \
  || fail 'Calibnet Blockscout verifier URL was not supplied'
if grep -q UpgradeableBeacon "$FORGE_LOG"; then fail 'ValidatorBeacon was submitted for verification'; fi

printf 'deployment commands: PASS\n'
