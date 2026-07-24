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
case "${1:-}" in
  chain-id) printf '%s\n' "${TEST_CHAIN_ID:-314}" ;;
  keccak) printf '%s\n' '0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2' ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != -C ]] || shift 2
case "${1:-}" in
  status)
    if [[ "${TEST_GIT_UNTRACKED:-0}" == 1 ]]; then printf '%s\n' '?? src/NewContract.sol'
    elif [[ "${TEST_GIT_DIRTY:-0}" != 0 ]]; then printf '%s\n' ' M src/PoRepMarket.sol'
    fi
    ;;
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
printf '{"contracts":{}}\n' >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
if "$SCRIPT" upgrade calibnet 2>"$tmp/error"; then fail 'missing targets succeeded'; fi
grep -q 'at least one upgrade target is required' "$tmp/error" || fail 'missing-target rejection was unclear'
if "$SCRIPT" upgrade calibnet PoRepMarket PoRepMarket 2>"$tmp/error"; then fail 'duplicate targets succeeded'; fi
grep -q 'duplicate upgrade target: PoRepMarket' "$tmp/error" || fail 'duplicate-target rejection was unclear'
if "$SCRIPT" upgrade calibnet Unknown 2>"$tmp/error"; then fail 'unknown target succeeded'; fi
grep -q 'unsupported upgrade target' "$tmp/error" || fail 'unknown-target rejection was unclear'
jq '.contracts.Unknown={kind:"uups",proxy:"0x1111111111111111111111111111111111111111",implementation:"0x1111111111111111111111111111111111111111",proxyCodeHash:"0x1111111111111111111111111111111111111111111111111111111111111111",implementationCodeHash:"0x1111111111111111111111111111111111111111111111111111111111111111"}' \
  "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
if "$SCRIPT" upgrade calibnet Unknown 2>"$tmp/error"; then fail 'unknown manifest target succeeded'; fi
grep -q 'unsupported upgrade target' "$tmp/error" || fail 'unknown manifest target rejection was unclear'
for rejected in ValidatorBeacon ExternalDependency; do
  jq --arg name "$rejected" '.contracts[$name]={kind:(if $name=="ValidatorBeacon" then "beacon" else "external" end),artifact:"src/Rejected.sol:Rejected",implementation:"0x1111111111111111111111111111111111111111",implementationCodeHash:"0x1111111111111111111111111111111111111111111111111111111111111111"}' \
    "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
  mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
  if "$SCRIPT" upgrade calibnet "$rejected" 2>"$tmp/error"; then fail "$rejected upgrade target succeeded"; fi
  grep -q 'unsupported upgrade target' "$tmp/error" || fail "$rejected rejection was unclear"
done
jq '.contracts.PoRepMarket={kind:"uups",artifact:"src/PoRepMarket.sol:PoRepMarket",implementation:"0x1111111111111111111111111111111111111111",implementationCodeHash:"0x1111111111111111111111111111111111111111111111111111111111111111"}' \
  "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
if "$SCRIPT" upgrade calibnet PoRepMarket 2>"$tmp/error"; then fail 'invalid UUPS manifest entry succeeded'; fi
grep -q 'unsupported upgrade target' "$tmp/error" || fail 'invalid UUPS manifest rejection was unclear'
jq '.contracts.PoRepMarket={kind:"uups",artifact:"src/SPRegistry.sol:SPRegistry",proxy:"0x1111111111111111111111111111111111111111",implementation:"0x1111111111111111111111111111111111111111",implementationCodeHash:"0x1111111111111111111111111111111111111111111111111111111111111111"}' \
  "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
if "$SCRIPT" upgrade calibnet PoRepMarket 2>"$tmp/error"; then fail 'wrong target artifact succeeded'; fi
grep -q 'unsupported upgrade target' "$tmp/error" || fail 'wrong target artifact rejection was unclear'

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
grep -q 'deployment source is dirty' "$tmp/error" || fail 'dirty-source rejection was unclear'
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran before clean-source check'

: >"$FORGE_LOG"
if TEST_GIT_UNTRACKED=1 CONFIRM_MAINNET=yes "$SCRIPT" deploy mainnet 2>"$tmp/error"; then
  fail 'mainnet deploy accepted untracked deployment source'
fi
grep -q 'deployment source is dirty' "$tmp/error" || fail 'untracked-source rejection was unclear'
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran before untracked-source check'

printf '{"release":{"buildInfoSha256":"0x%s"},"contracts":{}}\n' "$(printf 'a%.0s' {1..64})" >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
mkdir -p "$DEPLOYMENTS_ROOT/calibnet/build-info"
printf '{"output":{"contracts":{}}}\n' >"$tmp/verification-build.json"
names=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator)
for index in "${!names[@]}"; do
  name="${names[$index]}"; digit=$(( index + 1 ))
  address="0x$(printf '%040d' 0 | tr 0 "$digit")"
  artifact="src/$name.sol:$name"
  jq --arg name "$name" --arg address "$address" --arg artifact "$artifact" \
    '.contracts[$name]={kind:(if $name=="Validator" then "implementation" else "uups" end),implementation:$address,
      implementationCodeHash:"0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2",artifact:$artifact}' \
    "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
  mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
  jq --arg source "${artifact%%:*}" --arg contract "$name" \
    '.output.contracts[$source][$contract].evm.deployedBytecode={object:"01",immutableReferences:{}}' \
    "$tmp/verification-build.json" >"$tmp/verification-build.next"
  mv "$tmp/verification-build.next" "$tmp/verification-build.json"
done
jq --arg address "0x$(printf '8%.0s' {1..40})" \
  '.contracts.ValidatorBeacon={kind:"beacon",address:$address,implementation:$address,
    artifact:"lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon"}' \
  "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
jq '.contracts.FutureImplementation={kind:"implementation",implementation:"0x9999999999999999999999999999999999999999",
  implementationCodeHash:"0x5fe7f977e71dba2ea1a68e21057beebb9be2ac30c6410aa38d4f3fbe41dcffd2",artifact:"src/Future.sol:Future"}' \
  "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
jq '.output.contracts["src/Future.sol"].Future.evm.deployedBytecode={object:"01",immutableReferences:{}}' \
  "$tmp/verification-build.json" >"$tmp/verification-build.next"
mv "$tmp/verification-build.next" "$tmp/verification-build.json"
verification_hash="$(if command -v sha256sum >/dev/null; then sha256sum "$tmp/verification-build.json" | awk '{print $1}'; else shasum -a 256 "$tmp/verification-build.json" | awk '{print $1}'; fi)"
gzip -n -c "$tmp/verification-build.json" >"$DEPLOYMENTS_ROOT/calibnet/build-info/$verification_hash.json.gz"
jq --arg hash "0x$verification_hash" '.release.buildInfoSha256=$hash' "$DEPLOYMENTS_ROOT/calibnet/latest.json" >"$tmp/latest.next"
mv "$tmp/latest.next" "$DEPLOYMENTS_ROOT/calibnet/latest.json"
export RPC_CALIBNET=rpc
: >"$FORGE_LOG"
FORGE_EXIT=0 "$SCRIPT" verify calibnet
[[ "$(wc -l <"$FORGE_LOG" | tr -d ' ')" == 8 ]] || fail 'verification did not enumerate manifest implementations dynamically'
for index in "${!names[@]}"; do
  name="${names[$index]}"; digit=$(( index + 1 ))
  address="0x$(printf '%040d' 0 | tr 0 "$digit")"
  grep -q "verify-contract $address src/$name.sol:$name .* --watch" "$FORGE_LOG" \
    || fail "$name implementation was not verified with --watch"
done
grep -q 'verify-contract 0x9999999999999999999999999999999999999999 src/Future.sol:Future .* --watch' "$FORGE_LOG" \
  || fail 'new manifest implementation was not verified dynamically'
grep -q -- '--verifier-url https://filecoin-testnet.blockscout.com/api/' "$FORGE_LOG" \
  || fail 'Calibnet Blockscout verifier URL was not supplied'
[[ "$(grep -c -- '--skip-is-verified-check' "$FORGE_LOG")" == 8 ]] \
  || fail 'verification trusted stale Blockscout address metadata'
if grep -q UpgradeableBeacon "$FORGE_LOG"; then fail 'ValidatorBeacon was submitted for verification'; fi

: >"$FORGE_LOG"
if TEST_GIT_DIRTY=1 FORGE_EXIT=0 "$SCRIPT" verify calibnet 2>/dev/null; then fail 'dirty verification source succeeded'; fi
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran for dirty verification source'
cp "$DEPLOYMENTS_ROOT/calibnet/latest.json" "$tmp/verification-latest.json"

: >"$FORGE_LOG"
printf '{invalid\n' >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
if FORGE_EXIT=0 "$SCRIPT" verify calibnet 2>/dev/null; then fail 'malformed verification manifest succeeded'; fi
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran for malformed verification manifest'
jq '.contracts={}' "$tmp/verification-latest.json" >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
if FORGE_EXIT=0 "$SCRIPT" verify calibnet 2>/dev/null; then fail 'empty verification manifest succeeded'; fi
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran for empty verification manifest'
jq '.contracts={Broken:{kind:"uups",artifact:"src/Broken.sol:Broken"},Valid:{kind:"implementation",implementation:"0x1111111111111111111111111111111111111111",artifact:"src/Valid.sol:Valid"}}' "$tmp/verification-latest.json" >"$DEPLOYMENTS_ROOT/calibnet/latest.json"
if FORGE_EXIT=0 "$SCRIPT" verify calibnet 2>/dev/null; then fail 'invalid verification entry succeeded'; fi
[[ ! -s "$FORGE_LOG" ]] || fail 'Forge ran before rejecting invalid verification entry'

printf 'deployment commands: PASS\n'
