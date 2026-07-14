#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -r "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export DEPLOYMENTS_ROOT="$tmp/deployments"
export PENDING_ROOT="$tmp/pending"
export BROADCAST_ROOT="$tmp/broadcast"
export FLOW_LOG="$tmp/flow.log"
export FORGE_LOG="$tmp/forge.log"
export RPC_CALIBNET=rpc
export PRIVATE_KEY_CALIBNET=key
export FILECOIN_PAY_CALIBNET=0x1
export TERMINATION_ORACLE_CALIBNET=0x2
export ORACLE_CALIBNET=0x3
export POREP_SERVICE_CALIBNET=0x4
export META_ALLOCATOR_CALIBNET=0x5
export OPERATOR_ADDR_CALIBNET=0x6

export TEST_TX_HASH="0x$(printf 'a%.0s' {1..64})"
export TEST_BLOCK_HASH="0x$(printf 'b%.0s' {1..64})"
export TEST_ADDRESS="0x$(printf '1%.0s' {1..40})"
export TEST_UPGRADE_ADDRESS="0x$(printf '2%.0s' {1..40})"
export TEST_UPGRADE_CODE_HASH="0x$(printf '2%.0s' {1..64})"

cat >"$tmp/cast" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == chain-id ]] || exit 2
printf '314159\n'
EOF
cat >"$tmp/git" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" != -C ]] || shift 2
case "${1:-}" in
  rev-parse) printf '1111111111111111111111111111111111111111\n' ;;
  status) exit 0 ;;
  *) exit 2 ;;
esac
EOF
cat >"$tmp/forge" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FORGE_LOG"
if [[ "$1" == build ]]; then
  while (( $# )); do
    if [[ "$1" == --out ]]; then
      mkdir -p "$2/build-info"
      printf '{"actual":true}\n' >"$2/build-info/build.json"
      exit 0
    fi
    shift
  done
  exit 2
fi

printf 'broadcast\n' >>"$FLOW_LOG"
if [[ "$*" == *Upgrade.s.sol* ]]; then
  script=Upgrade.s.sol
else
  script=Deploy.s.sol
fi
mkdir -p "$BROADCAST_ROOT/$script/314159"
jq -n --arg hash "$TEST_TX_HASH" --arg block "$TEST_BLOCK_HASH" '
  {transactions:[{hash:$hash}],receipts:[{transactionHash:$hash,status:"0x1",
    blockNumber:"0x2",blockHash:$block,contractAddress:null}]}
' >"$BROADCAST_ROOT/$script/314159/run-200.json"
cp "$BROADCAST_ROOT/$script/314159/run-200.json" "$BROADCAST_ROOT/$script/314159/run-latest.json"

if [[ "$script" != Deploy.s.sol ]]; then
  jq --arg names "$UPGRADE_CONTRACT_NAMES" --arg implementation "$TEST_UPGRADE_ADDRESS" --arg code_hash "$TEST_UPGRADE_CODE_HASH" '
    ($names | split(",")) as $targets | .operations=[$targets[] | {target:.,kind:(if .=="Validator" then "beacon" else "uups" end),artifact:("src/" + . + ".sol:" + .),newImplementation:$implementation,newImplementationCodeHash:$code_hash}]
  ' "$UPGRADE_OUTPUT" >"$UPGRADE_OUTPUT.next"
  mv "$UPGRADE_OUTPUT.next" "$UPGRADE_OUTPUT"
  exit 0
fi

git_commit="$(jq -r .release.gitCommit "$DEPLOYMENT_OUTPUT")"
build_hash="$(jq -r .release.buildInfoSha256 "$DEPLOYMENT_OUTPUT")"
jq --arg git "$git_commit" --arg build "$build_hash" --arg i "$TEST_ADDRESS" '
  .result={status:"pending",deployer:$i,release:{gitCommit:$git,buildInfoSha256:$build},
    contracts:{
      PoRepMarket:{kind:"uups",artifact:"src/PoRepMarket.sol:PoRepMarket",proxy:$i,implementation:$i,proxyCodeHash:"0x1",implementationCodeHash:"0x1"},
      ValidatorFactory:{kind:"uups",artifact:"src/ValidatorFactory.sol:ValidatorFactory",proxy:$i,implementation:$i,proxyCodeHash:"0x1",implementationCodeHash:"0x1"},
      DataCapEvidenceAdapter:{kind:"uups",artifact:"src/DataCapEvidenceAdapter.sol:DataCapEvidenceAdapter",proxy:$i,implementation:$i,proxyCodeHash:"0x1",implementationCodeHash:"0x1"},
      SPRegistry:{kind:"uups",artifact:"src/SPRegistry.sol:SPRegistry",proxy:$i,implementation:$i,proxyCodeHash:"0x1",implementationCodeHash:"0x1"},
      SLIOracle:{kind:"uups",artifact:"src/SLIOracle.sol:SLIOracle",proxy:$i,implementation:$i,proxyCodeHash:"0x1",implementationCodeHash:"0x1"},
      SLIScorer:{kind:"uups",artifact:"src/SLIScorer.sol:SLIScorer",proxy:$i,implementation:$i,proxyCodeHash:"0x1",implementationCodeHash:"0x1"},
      Validator:{kind:"implementation",artifact:"src/Validator.sol:Validator",implementation:$i,implementationCodeHash:"0x1"},
      ValidatorBeacon:{kind:"beacon",artifact:"lib/openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol:UpgradeableBeacon",address:$i,implementation:$i,factoryProxy:$i}
    },externalDependencies:{FilecoinPay:"0x1",PoRepService:"0x4",MetaAllocator:"0x5",
      TerminationOracle:"0x2",Oracle:"0x3",Operator:"0x6"}}
' "$DEPLOYMENT_OUTPUT" >"$DEPLOYMENT_OUTPUT.next"
mv "$DEPLOYMENT_OUTPUT.next" "$DEPLOYMENT_OUTPUT"
EOF
cat >"$tmp/finality" <<'EOF'
#!/usr/bin/env bash
printf 'finality\n' >>"$FLOW_LOG"
[[ "${FINALITY_READY:-0}" == 1 ]]
EOF
cat >"$tmp/live" <<'EOF'
#!/usr/bin/env bash
printf 'live\n' >>"$FLOW_LOG"
EOF
cat >"$tmp/storage" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STORAGE_LOG"
printf '%s: valid\n' PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator
EOF
chmod +x "$tmp/cast" "$tmp/git" "$tmp/forge" "$tmp/finality" "$tmp/live" "$tmp/storage"

export CAST_BIN="$tmp/cast"
export GIT_BIN="$tmp/git"
export FORGE_BIN="$tmp/forge"
export FINALITY_VERIFIER="$tmp/finality"
export LIVE_CHECKER="$tmp/live"
export STORAGE_VALIDATOR="$tmp/storage"
export STORAGE_LOG="$tmp/storage.log"

source "$ROOT/script/deployment.sh"

names=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator)
printf '{"output":{"contracts":{}}}\n' >"$tmp/reference.json"
cp "$tmp/reference.json" "$tmp/current.json"
printf '{"contracts":{}}\n' >"$tmp/storage-manifest.json"
: >"$tmp/expected-oz.log"
for name in "${names[@]}"; do
  artifact="src/$name.sol:$name"
  source_path="${artifact%%:*}"
  jq --arg source "$source_path" --arg name "$name" \
    '.output.contracts[$source][$name].storageLayout={storage:[],types:{}}' \
    "$tmp/reference.json" >"$tmp/reference.next"
  mv "$tmp/reference.next" "$tmp/reference.json"
  jq --arg source "$source_path" --arg name "$name" \
    '.output.contracts[$source][$name].storageLayout={storage:[],types:{}}' \
    "$tmp/current.json" >"$tmp/current.next"
  mv "$tmp/current.next" "$tmp/current.json"
  jq --arg name "$name" --arg artifact "$artifact" '.contracts[$name].artifact=$artifact' \
    "$tmp/storage-manifest.json" >"$tmp/storage-manifest.next"
  mv "$tmp/storage-manifest.next" "$tmp/storage-manifest.json"
  printf '%s\n' "$artifact" >>"$tmp/expected-oz.log"
done
gzip -n -c "$tmp/reference.json" >"$tmp/reference.json.gz"
gzip -n -c "$tmp/current.json" >"$tmp/current.json.gz"
cat >"$tmp/oz" <<'EOF'
#!/usr/bin/env bash
while (( $# )); do
  if [[ "$1" == --contract ]]; then printf '%s\n' "$2" >>"$OZ_LOG"; fi
  shift
done
EOF
chmod +x "$tmp/oz"
export OZ_LOG="$tmp/oz.log"
reference_hash="0x$(sha256_file "$tmp/reference.json")"
current_hash="0x$(sha256_file "$tmp/current.json")"
OZ_BIN="$tmp/oz" "$ROOT/script/validate-storage-layout.sh" \
  --manifest "$tmp/storage-manifest.json" \
  --reference-build-info "$tmp/reference.json.gz" --reference-sha256 "$reference_hash" \
  --current-build-info "$tmp/current.json.gz" --current-sha256 "$current_hash" >"$tmp/storage.txt"
printf '%s\n' "${names[@]/%/: valid}" >"$tmp/expected-storage.txt"
cmp -s "$tmp/storage.txt" "$tmp/expected-storage.txt" || fail 'storage report is not the fixed seven-contract result'
cmp -s "$OZ_LOG" "$tmp/expected-oz.log" || fail 'storage validation order is wrong'
: >"$OZ_LOG"
printf ' ' >>"$tmp/reference.json"
gzip -n -c "$tmp/reference.json" >"$tmp/reference.json.gz"
if OZ_BIN="$tmp/oz" "$ROOT/script/validate-storage-layout.sh" \
  --manifest "$tmp/storage-manifest.json" \
  --reference-build-info "$tmp/reference.json.gz" --reference-sha256 "$reference_hash" \
  --current-build-info "$tmp/current.json.gz" --current-sha256 "$current_hash" >/dev/null 2>&1; then
  fail 'changed reference build-info was accepted'
fi
[[ ! -s "$OZ_LOG" ]] || fail 'OpenZeppelin ran before reference authentication'

mkdir -p "$BROADCAST_ROOT/Deploy.s.sol/314159"
printf '{}\n' >"$BROADCAST_ROOT/Deploy.s.sol/314159/run-latest.json"
cmd_deploy calibnet --fresh
pending="$PENDING_ROOT/calibnet/pending-deploy.json"
broadcast="$BROADCAST_ROOT/Deploy.s.sol/314159/run-200.json"

jq -e '.status=="pending" and .operation=="deploy" and .network=="calibnet"
  and .chainId==314159 and .result.status=="pending"
  and .broadcast.path=="broadcast/Deploy.s.sol/314159/run-200.json"
  and (.broadcast.sha256|test("^0x[0-9a-f]{64}$"))' "$pending" >/dev/null
[[ ! -e "$DEPLOYMENTS_ROOT/calibnet/latest.json" ]] || fail 'deploy published canonical state'
[[ "$(cat "$FLOW_LOG")" == broadcast ]] || fail 'deploy ran finalization checks'

cp "$broadcast" "$tmp/good-broadcast.json"
jq 'del(.broadcast)' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'deploy finalized before Filecoin finality'; fi
jq -e '.broadcast.path=="broadcast/Deploy.s.sol/314159/run-200.json"' "$pending" >/dev/null \
  || fail 'finalizer did not recover immutable broadcast evidence'
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'recovered finalizer order is wrong'
[[ ! -e "$DEPLOYMENTS_ROOT/calibnet/latest.json" ]] || fail 'early finalizer published latest'

jq '.receipts += [.receipts[0]]' "$broadcast" >"$broadcast.next"
mv "$broadcast.next" "$broadcast"
replacement_hash="0x$(printf 'f%.0s' {1..64})"
jq --arg replacement "$replacement_hash" \
  '.pending=[.transactions[0].hash] | .receipts[].transactionHash=$replacement' \
  "$broadcast" >"$broadcast.next"
mv "$broadcast.next" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'deploy finalized before Filecoin finality'; fi
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'identical replacement receipt observations were rejected'

conflicting_observation="0x$(printf 'e%.0s' {1..64})"
jq --arg block "$conflicting_observation" '.receipts[1].blockHash=$block' "$broadcast" >"$broadcast.next"
mv "$broadcast.next" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
: >"$FLOW_LOG"
if (cmd_finalize_deploy calibnet) 2>/dev/null; then fail 'conflicting receipt observation finalized'; fi
[[ ! -s "$FLOW_LOG" ]] || fail 'conflicting receipt observation reached finality check'

cp "$tmp/good-broadcast.json" "$broadcast"
jq --arg hash "0x$(sha256_file "$broadcast")" '.broadcast.sha256=$hash' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

conflicting="$tmp/conflicting-blocks.json"
second_hash="0x$(printf 'c%.0s' {1..64})"
second_block="0x$(printf 'd%.0s' {1..64})"
jq --arg hash "$second_hash" --arg block "$second_block" \
  '.transactions += [{hash:$hash}] | .receipts += [{transactionHash:$hash,status:"0x1",blockNumber:"0x2",blockHash:$block,contractAddress:null}]' \
  "$broadcast" >"$conflicting"
if (successful_receipts "$conflicting" "$tmp/conflicting-receipts.json") 2>/dev/null; then
  fail 'conflicting block hashes were accepted'
fi

: >"$FLOW_LOG"
FINALITY_READY=1 cmd_finalize_deploy calibnet
latest="$DEPLOYMENTS_ROOT/calibnet/latest.json"
deployment_id="$(jq -r .deploymentId "$latest")"
[[ -f "$DEPLOYMENTS_ROOT/calibnet/history/$deployment_id.json" ]] || fail 'history was not published'
build_hash="$(jq -r '.release.buildInfoSha256[2:]' "$latest")"
[[ -f "$DEPLOYMENTS_ROOT/calibnet/build-info/$build_hash.json.gz" ]] || fail 'build-info was not retained'
[[ "$(tr '\n' ' ' <"$FLOW_LOG")" == 'finality live ' ]] || fail 'finalizer order is wrong'

latest_hash="$(sha256_file "$latest")"
history_hash="$(sha256_file "$DEPLOYMENTS_ROOT/calibnet/history/$deployment_id.json")"
FINALITY_READY=1 cmd_finalize_deploy calibnet
[[ "$(sha256_file "$latest")" == "$latest_hash" ]] || fail 'second finalizer rewrote latest'
[[ "$(sha256_file "$DEPLOYMENTS_ROOT/calibnet/history/$deployment_id.json")" == "$history_hash" ]] \
  || fail 'second finalizer rewrote history'

source_hash="$(sha256_file "$latest")"
: >"$FLOW_LOG"
cmd_upgrade calibnet PoRepMarket SPRegistry Validator
pending="$PENDING_ROOT/calibnet/pending-upgrade.json"
jq -e '.status=="pending" and .operation=="upgrade" and .targets==["PoRepMarket","SPRegistry","Validator"]
  and .broadcast.path=="broadcast/Upgrade.s.sol/314159/run-200.json"
  and (.release.storageReportSha256|test("^0x[0-9a-f]{64}$"))
  and [.operations[].target]==.targets and [.operations[].kind]==["uups","uups","beacon"]' "$pending" >/dev/null
[[ "$(sha256_file "$latest")" == "$source_hash" ]] || fail 'upgrade broadcast changed latest'
[[ "$(cat "$FLOW_LOG")" == broadcast ]] || fail 'upgrade broadcast ran finalization checks'

: >"$FLOW_LOG"
if (cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'upgrade finalized before Filecoin finality'; fi
[[ "$(cat "$FLOW_LOG")" == finality ]] || fail 'upgrade finalizer order is wrong'
[[ "$(sha256_file "$latest")" == "$source_hash" ]] || fail 'early upgrade finalizer changed latest'

jq '.targets += [.targets[0]] | .operations += [.operations[0]]' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'duplicate upgrade target finalized'; fi
jq 'del(.targets[-1], .operations[-1])' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

jq '.operations[0].artifact="src/Tampered.sol:Tampered"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"
if (FINALITY_READY=1 cmd_finalize_upgrade calibnet) 2>/dev/null; then fail 'tampered upgrade operation finalized'; fi
jq '.operations[0].artifact="src/PoRepMarket.sol:PoRepMarket"' "$pending" >"$pending.next"
mv "$pending.next" "$pending"

: >"$FLOW_LOG"
FINALITY_READY=1 cmd_finalize_upgrade calibnet
[[ "$(jq -r .contracts.PoRepMarket.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] \
  || fail 'finalizer did not update selected implementation'
[[ "$(jq -r .contracts.SPRegistry.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] || fail 'finalizer did not update second implementation'
[[ "$(jq -r .contracts.Validator.implementation "$latest")" == "$TEST_UPGRADE_ADDRESS" ]] || fail 'finalizer did not update Validator implementation'
upgrade_id="$(jq -r .upgradeId "$pending")"
record="$DEPLOYMENTS_ROOT/calibnet/upgrades/$upgrade_id.json"
[[ -f "$record" ]] || fail 'upgrade record was not published'
[[ "$(tr '\n' ' ' <"$FLOW_LOG")" == 'finality live ' ]] || fail 'upgrade finalizer order is wrong'

latest_hash="$(sha256_file "$latest")"
record_hash="$(sha256_file "$record")"
FINALITY_READY=1 cmd_finalize_upgrade calibnet
[[ "$(sha256_file "$latest")" == "$latest_hash" ]] || fail 'second upgrade finalizer rewrote latest'
[[ "$(sha256_file "$record")" == "$record_hash" ]] || fail 'second upgrade finalizer rewrote record'

printf 'deployment flow: PASS\n'
