#!/bin/bash
#
# Filecoin Pay Retrieval Operator — Blockscout contract verification.
#
# Subcommands:
#   verify     <chain_id>
#       Verify every address in deployments/<network>/retrieval-operator-latest.json on
#       Blockscout, then audit the result.
#
#   audit      <chain_id>
#       Read-only: confirm every address in
#       deployments/<network>/retrieval-operator-latest.json is already verified
#       on Blockscout with matching compiler settings.
#       Requires no RPC; safe to run in CI without secrets.
#
#   verify-one <chain_id> <address> <contract_name>
#       Manual single-address fallback for addresses outside the allowlist.
#
# Exit codes:
#   0  all targets verified
#   1  one or more targets failed
#   2  usage or unsupported chain
#   3  environment check failure (missing tool, wrong chain, missing manifest,
#      mainnet without CONFIRM_MAINNET=yes)
#
set -euo pipefail
IFS=$'\n\t'

cd "$(dirname "$0")/.."

# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────

# Chain metadata table. Only calibnet + mainnet are supported.
# Columns: network  rpc_env_var  blockscout_api_root  blockscout_web_root
readonly CHAIN_META_314="mainnet RPC_MAINNET https://filecoin.blockscout.com https://filecoin.blockscout.com"
readonly CHAIN_META_314159="calibnet RPC_CALIBNET https://filecoin-testnet.blockscout.com https://filecoin-testnet.blockscout.com"

# Allowlist of deployed targets. Each row: manifest_jq_path | kind | contract_name
# Kept in sync with script/Deploy.s.sol and script/utils/DeployUtils.sol.
# Changing Deploy.s.sol WITHOUT updating this list will fail the count invariant.
readonly ALLOWLIST=(
  "OperatorFactory.proxy|PROXY|ERC1967Proxy"
  "OperatorFactory.impl|IMPL|OperatorFactory"
  "Operator.beacon|BEACON|UpgradeableBeacon"
  "Operator.impl|IMPL|Operator"
)

readonly EXPECTED_COMPILER_PREFIX="v0.8.30"
readonly EXPECTED_OPTIMIZER_RUNS="200"
readonly EXPECTED_EVM_VERSION="prague"

# ─────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────

LOG_FILE=""
COLOR_ENABLED=1
[[ -t 2 ]] || COLOR_ENABLED=0
[[ "${NO_COLOR:-}" == "" ]] || COLOR_ENABLED=0

_strip_ansi() { sed -E 's/\x1B\[[0-9;]*[a-zA-Z]//g'; }

_log() {
  local level="$1"; shift
  local ts msg color reset=''
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  msg="$*"
  if (( COLOR_ENABLED )); then
    reset=$'\033[0m'
    case "$level" in
      INFO)  color=$'\033[0;36m' ;;
      WARN)  color=$'\033[0;33m' ;;
      ERROR) color=$'\033[0;31m' ;;
      OK)    color=$'\033[0;32m' ;;
      *)     color='' ;;
    esac
  else
    color=''
  fi
  printf '%s[%s] %-5s %s%s\n' "$color" "$ts" "$level" "$msg" "$reset" >&2
  if [[ -n "$LOG_FILE" ]]; then
    printf '[%s] %-5s %s\n' "$ts" "$level" "$msg" >>"$LOG_FILE"
  fi
}

_die() {
  local code="${2:-1}"
  _log ERROR "$1"
  exit "$code"
}

_init_log_file() {
  local action="$1" network="$2"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p deployments
  LOG_FILE="deployments/${action}-${network}-${ts}.log"
  : >"$LOG_FILE"
  _log INFO "Log: $LOG_FILE"
}

# Symlink deployments/verify-<network>-latest.{log,json} → latest run.
# Uses `ln -sfn` which is atomic on macOS and Linux.
_publish_latest() {
  local action="$1" network="$2" latest target
  for ext in log json; do
    latest="deployments/${action}-${network}-latest.${ext}"
    case "$ext" in
      log)  target="$LOG_FILE" ;;
      json) target="${LOG_FILE%.log}.json" ;;
    esac
    [[ -e "$target" ]] || continue
    ln -sfn "$(basename "$target")" "$latest"
  done
}

# ─────────────────────────────────────────────────────────────────────
# Retry helper
# ─────────────────────────────────────────────────────────────────────
#
# Usage: _retry <max_attempts> <command> [args...]
# Exponential backoff: 2s, 4s, 8s, 16s, 32s, capped at 60s.
# On permanent failure, writes captured stderr+stdout to our stderr and
# returns the last command's exit code. On success, writes captured
# stdout to our stdout.

_retry() {
  local max="$1"; shift
  local attempt=1 delay=2 out rc
  while :; do
    if out="$("$@" 2>&1)"; then
      printf '%s' "$out"
      return 0
    else
      rc=$?
    fi
    if (( attempt >= max )); then
      printf '%s' "$out" >&2
      return "$rc"
    fi
    _log WARN "attempt $attempt/$max failed (rc=$rc), retrying in ${delay}s"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    (( delay > 60 )) && delay=60
  done
}

# ─────────────────────────────────────────────────────────────────────
# Chain + environment checks
# ─────────────────────────────────────────────────────────────────────

# Echoes: network rpc_env api_root web_root
_chain_meta() {
  local chain="$1"
  local var="CHAIN_META_${chain}"
  local meta="${!var:-}"
  [[ -n "$meta" ]] \
    || _die "Unsupported chain id: $chain (only 314 mainnet and 314159 calibnet are supported)" 2
  echo "$meta"
}

_require_tool() {
  command -v "$1" >/dev/null 2>&1 || _die "Missing required tool: $1" 3
}

_check_common() {
  [[ -f foundry.toml ]] || _die "Must be run from repo root (foundry.toml not found in $(pwd))" 3
  _require_tool jq
  _require_tool curl
}

# Checks for subcommands that need an RPC (verify, verify-one).
# Echoes: network rpc api web
_check_rpc() {
  local chain="$1"
  _check_common
  _require_tool forge
  _require_tool cast

  local meta
  meta="$(_chain_meta "$chain")" || exit $?
  local network rpc_env api web
  IFS=' ' read -r network rpc_env api web <<<"$meta"

  if [[ "$network" == "mainnet" && "${CONFIRM_MAINNET:-}" != "yes" ]]; then
    _die "Refusing mainnet operation. Set CONFIRM_MAINNET=yes to proceed." 3
  fi

  local rpc="${!rpc_env:-}"
  [[ -n "$rpc" ]] || _die "RPC env var '$rpc_env' is empty or unset" 3

  local actual
  actual="$(_retry 3 cast chain-id --rpc-url "$rpc")" \
    || _die "RPC $rpc_env is unreachable" 3
  [[ "$actual" == "$chain" ]] \
    || _die "RPC $rpc_env points at chain $actual, expected $chain" 3

  echo "$network $rpc $api $web"
}

# Checks for audit (no RPC, no forge, no cast needed).
# Echoes: network api web
_check_audit() {
  local chain="$1"
  _check_common

  local meta
  meta="$(_chain_meta "$chain")" || exit $?
  local network rpc_env api web
  IFS=' ' read -r network rpc_env api web <<<"$meta"

  if [[ "$network" == "mainnet" && "${AUDIT_ALLOW_MAINNET:-yes}" != "yes" ]]; then
    _die "Refusing mainnet audit (AUDIT_ALLOW_MAINNET=no)" 3
  fi

  echo "$network $api $web"
}

# ─────────────────────────────────────────────────────────────────────
# Manifest loading
# ─────────────────────────────────────────────────────────────────────

_manifest_path() {
  local network="$1"
  echo "deployments/${network}/retrieval-operator-latest.json"
}

# Asserts manifest exists and its chainId matches the target.
_require_manifest() {
  local chain="$1" network="$2"
  local manifest
  manifest="$(_manifest_path "$network")"
  [[ -f "$manifest" ]] || _die "Missing manifest: $manifest" 3
  local actual_chain
  actual_chain="$(jq -r '.chainId // empty' "$manifest")"
  [[ "$actual_chain" == "$chain" ]] \
    || _die "$manifest has chainId $actual_chain, expected $chain" 3
  echo "$manifest"
}

# Expands the allowlist into lines of: address|kind|contract_name
# Fails if any allowlist entry is missing from the manifest.
_expand_allowlist() {
  local manifest="$1"
  local count=0 entry jq_path kind name addr
  for entry in "${ALLOWLIST[@]}"; do
    IFS='|' read -r jq_path kind name <<<"$entry"
    addr="$(jq -r ".${jq_path} // empty" "$manifest")"
    [[ -n "$addr" && "$addr" != "null" ]] \
      || _die "manifest $manifest is missing .${jq_path} — allowlist drift?" 1
    printf '%s|%s|%s\n' "$(_lower "$addr")" "$kind" "$name"
    count=$((count + 1))
  done
  [[ $count -eq ${#ALLOWLIST[@]} ]] \
    || _die "allowlist length mismatch: got $count, expected ${#ALLOWLIST[@]}" 1
}

_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# ─────────────────────────────────────────────────────────────────────
# Build artifact helpers
# ─────────────────────────────────────────────────────────────────────

_artifact_path() {
  local name="$1"
  echo "out/${name}.sol/${name}.json"
}

# Returns "<relative-path>:<Name>" from the compilation metadata.
# This is authoritative — it locates OZ contracts under lib/ without
# any filesystem search.
_resolve_source_target() {
  local name="$1"
  local art
  art="$(_artifact_path "$name")"
  [[ -f "$art" ]] \
    || _die "Build artifact not found: $art (run 'forge build' first)" 1
  jq -r '
    .metadata.settings.compilationTarget
    | to_entries
    | if length != 1 then
        error("compilationTarget must have exactly one key")
      else . end
    | .[0]
    | "\(.key):\(.value)"
  ' "$art" || _die "Failed to parse compilation target from $art" 1
}

_creation_bytecode_hex() {
  local name="$1"
  jq -r '.bytecode.object' "$(_artifact_path "$name")"
}

# ─────────────────────────────────────────────────────────────────────
# Blockscout API helpers
# ─────────────────────────────────────────────────────────────────────

# GET <api>/api/v2/<path>  →  stdout JSON body
_bs_get() {
  local api="$1" path="$2"
  curl -sS -f --connect-timeout 10 --max-time 30 \
    -H 'Accept: application/json' \
    "${api}/api/v2/${path#/}"
}

# Fetches a smart-contract record. Unverified addresses return 200 with
# is_verified:false (not 404), so we can always decode the JSON.
_bs_smart_contract() {
  local api="$1" addr="$2"
  _bs_get "$api" "smart-contracts/$addr"
}

# Fetches an address record. Used to find creation_transaction_hash.
_bs_address() {
  local api="$1" addr="$2"
  _bs_get "$api" "addresses/$addr"
}

# Fetches a tx record. Used to get raw_input (creation calldata).
_bs_transaction() {
  local api="$1" txhash="$2"
  _bs_get "$api" "transactions/$txhash"
}

# ─────────────────────────────────────────────────────────────────────
# Audit: is_verified check with compiler-settings match
# ─────────────────────────────────────────────────────────────────────
#
# A single row is considered PASS only if the Blockscout v2 API reports:
#   is_verified: true
#   language: "solidity"
#   compiler_version starts with "v0.8.30"
#   optimization_enabled: true
#   optimization_runs: 200
#   evm_version: "prague"
#
# Any other combination is FAIL. "Verified but with wrong settings" is FAIL,
# not PASS — we refuse to approve a mismatched match.

_audit_one() {
  local api="$1" addr="$2"
  local body tries=1 max=5 delay=2

  while :; do
    if body="$(_bs_smart_contract "$api" "$addr" 2>/dev/null)"; then
      # Valid JSON response. Evaluate verification state.
      local is_verified language compiler optrun optenabled evm
      is_verified="$(jq -r '.is_verified // false' <<<"$body")"
      language="$(jq -r '.language // empty' <<<"$body")"
      compiler="$(jq -r '.compiler_version // empty' <<<"$body")"
      optrun="$(jq -r '.optimization_runs // empty' <<<"$body")"
      optenabled="$(jq -r '.optimization_enabled // false' <<<"$body")"
      evm="$(jq -r '.evm_version // empty' <<<"$body")"

      if [[ "$is_verified" != "true" ]]; then
        echo "not_verified"
        return 1
      fi
      [[ "$language" == "solidity" ]] \
        || { echo "wrong_language:$language"; return 1; }
      [[ "$compiler" == ${EXPECTED_COMPILER_PREFIX}* ]] \
        || { echo "wrong_compiler:$compiler"; return 1; }
      [[ "$optenabled" == "true" ]] \
        || { echo "optimizer_disabled"; return 1; }
      [[ "$optrun" == "$EXPECTED_OPTIMIZER_RUNS" ]] \
        || { echo "wrong_optimizer_runs:$optrun"; return 1; }
      [[ "$evm" == "$EXPECTED_EVM_VERSION" ]] \
        || { echo "wrong_evm_version:$evm"; return 1; }
      echo "ok"
      return 0
    fi

    if (( tries >= max )); then
      echo "unreachable"
      return 1
    fi
    _log WARN "audit $addr attempt $tries/$max failed, retrying in ${delay}s"
    sleep "$delay"
    tries=$((tries + 1))
    delay=$((delay * 2))
    (( delay > 60 )) && delay=60
  done
}

# ─────────────────────────────────────────────────────────────────────
# Creation-args extraction
# ─────────────────────────────────────────────────────────────────────
#
# Deterministic extraction:
#   1. Query Blockscout's smart-contracts/<addr>.creation_bytecode, which
#      works uniformly for top-level deploys AND inner CREATE (e.g. the
#      UpgradeableBeacon produced by OperatorFactory.initialize). For
#      inner creates, the tx-based path would return the PARENT tx's
#      input, which does not start with the child contract's bytecode.
#   2. Fall back to addresses/<addr>.creation_transaction_hash →
#      transactions/<hash>.raw_input if creation_bytecode is empty.
#   3. Assert the on-chain creation code starts with the compiled
#      bytecode.object from the current build. If not → HEAD source
#      drift, fail loudly.
#   4. Return the suffix as ABI-encoded constructor args (may be empty).

# Echoes: on-chain creation bytecode including ABI-encoded constructor args.
# Blockscout v2 returns creation_bytecode for both top-level and inner
# CREATE contracts as long as the indexer has traced the transaction.
_bs_creation_bytecode() {
  local api="$1" addr="$2"
  local body out
  body="$(_retry 5 _bs_smart_contract "$api" "$addr")" || return 1
  out="$(jq -r '.creation_bytecode // empty' <<<"$body")"
  [[ -n "$out" && "$out" != "null" ]] || return 1
  printf '%s' "$out"
}

# Fallback for addresses that Blockscout has not traced into the
# smart-contracts endpoint but still lists a creation_transaction_hash.
_bs_creation_from_tx() {
  local api="$1" addr="$2"
  local body tx tx_body raw
  body="$(_retry 5 _bs_address "$api" "$addr")" || return 1
  tx="$(jq -r '.creation_transaction_hash // .creation_tx_hash // empty' <<<"$body")"
  [[ -n "$tx" && "$tx" != "null" ]] || return 1
  tx_body="$(_retry 5 _bs_transaction "$api" "$tx")" || return 1
  raw="$(jq -r '.raw_input // empty' <<<"$tx_body")"
  [[ -n "$raw" && "$raw" != "null" ]] || return 1
  printf '%s' "$raw"
}

# Echoes: hex string (no 0x prefix) of constructor args. Empty for impls.
_extract_constructor_args() {
  local api="$1" name="$2" addr="$3"

  local creation=""
  creation="$(_bs_creation_bytecode "$api" "$addr" 2>/dev/null || true)"
  if [[ -z "$creation" ]]; then
    creation="$(_bs_creation_from_tx "$api" "$addr" 2>/dev/null || true)"
  fi
  if [[ -z "$creation" ]]; then
    _log ERROR "Blockscout has no creation bytecode for $addr"
    _log ERROR "  Tried: smart-contracts/$addr.creation_bytecode and addresses/$addr.creation_transaction_hash"
    return 1
  fi

  local bytecode
  bytecode="$(_creation_bytecode_hex "$name")"

  # Both hex strings are 0x-prefixed; compare after strip.
  local raw_hex="${creation#0x}"
  local bc_hex="${bytecode#0x}"
  local bc_len=${#bc_hex}

  if [[ "${raw_hex:0:$bc_len}" != "$bc_hex" ]]; then
    _log ERROR "Creation bytecode mismatch for $name at $addr"
    _log ERROR "  Built locally: ${bc_hex:0:40}...${bc_hex: -40} (${bc_len} hex chars)"
    _log ERROR "  On-chain:      ${raw_hex:0:40}...${raw_hex: -40} (${#raw_hex} hex chars)"
    _log ERROR "HEAD source does not compile to the deployed bytecode."
    _log ERROR "Likely cause: HEAD has drifted since the deployment."
    _log ERROR "Fix: checkout the commit that wrote deployments/<network>/retrieval-operator-latest.json"
    _log ERROR "     (hint: git log -- deployments/)"
    return 1
  fi

  printf '%s' "${raw_hex:$bc_len}"
}

# ─────────────────────────────────────────────────────────────────────
# forge verify-contract wrapper
# ─────────────────────────────────────────────────────────────────────
#
# Handles:
#   * already-verified → treated as success
#   * --watch makes the call synchronous wrt Blockscout's indexer
#   * --constructor-args is always passed explicitly (empty for impls)

_forge_verify() {
  local chain="$1" api="$2" addr="$3" target="$4" args_hex="$5"

  local out rc
  set +e
  if [[ -n "$args_hex" ]]; then
    out="$(forge verify-contract \
            "$addr" \
            "$target" \
            --verifier blockscout \
            --verifier-url "${api%/}/api/" \
            --chain "$chain" \
            --watch \
            --skip-is-verified-check \
            --constructor-args "0x$args_hex" \
            2>&1)"
  else
    out="$(forge verify-contract \
            "$addr" \
            "$target" \
            --verifier blockscout \
            --verifier-url "${api%/}/api/" \
            --chain "$chain" \
            --watch \
            --skip-is-verified-check \
            2>&1)"
  fi
  rc=$?
  set -e

  if [[ $rc -eq 0 ]] \
    || grep -qiE 'already (verified|is verified)|pass - verified|successfully verified' <<<"$out"; then
    _log OK "verify-contract succeeded: $target @ $addr"
    return 0
  fi

  _log ERROR "forge verify-contract failed (rc=$rc) for $target @ $addr"
  while IFS= read -r line; do
    [[ -n "$line" ]] && _log ERROR "    $line"
  done <<<"$out"
  return 1
}

# Audit with indexer-lag tolerance. Blockscout's v2 smart-contracts
# endpoint can take up to ~60 seconds after forge's --watch returns before
# it reports is_verified: true. Retry with backoff until the indexer catches
# up, or give up after ~90s total.
_audit_with_lag() {
  local api="$1" addr="$2"
  local attempt=1 max=6 delay=5 result
  while :; do
    result="$(_audit_one "$api" "$addr" || true)"
    if [[ "$result" == "ok" ]]; then
      echo "$result"
      return 0
    fi
    if (( attempt >= max )); then
      echo "$result"
      return 1
    fi
    _log INFO "  audit lag: attempt $attempt/$max got '$result', waiting ${delay}s for Blockscout indexer"
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
    (( delay > 30 )) && delay=30
  done
}

# ─────────────────────────────────────────────────────────────────────
# Reporting
# ─────────────────────────────────────────────────────────────────────

# Initialize the summary file with an empty rows array.
_init_summary() {
  local out_json="$1"
  echo '{"rows":[]}' >"$out_json"
}

# Emit a structured JSON row to the summary file (append).
_emit_row() {
  local out_json="$1" contract="$2" kind="$3" addr="$4" submit="$5" audit="$6" note="$7"
  local row
  row="$(jq -n \
    --arg contract "$contract" \
    --arg kind "$kind" \
    --arg addr "$addr" \
    --arg submit "$submit" \
    --arg audit "$audit" \
    --arg note "$note" \
    '{contract:$contract, kind:$kind, address:$addr, submit:$submit, audit:$audit, note:$note}')"
  jq --argjson row "$row" '.rows += [$row]' "$out_json" >"${out_json}.tmp"
  mv "${out_json}.tmp" "$out_json"
}

_finalize_summary() {
  local out_json="$1" chain="$2" network="$3" api="$4" web="$5" status="$6"
  local tmp
  tmp="${out_json}.tmp"
  jq \
    --arg chain "$chain" \
    --arg network "$network" \
    --arg api "$api" \
    --arg web "$web" \
    --arg status "$status" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {chainId:$chain, network:$network, blockscoutApi:$api, blockscoutWeb:$web, status:$status, generatedAt:$ts}' \
    "$out_json" >"$tmp"
  mv "$tmp" "$out_json"
}

_print_table() {
  local out_json="$1"
  printf '\n%-20s %-6s %-42s %-8s %-8s  %s\n' \
    CONTRACT KIND ADDRESS SUBMIT AUDIT NOTE
  printf '%s\n' "$(printf '─%.0s' {1..110})"
  jq -r '.rows[] | [.contract, .kind, .address, .submit, .audit, .note] | @tsv' "$out_json" \
    | while IFS=$'\t' read -r c k a s au n; do
        printf '%-20s %-6s %-42s %-8s %-8s  %s\n' "$c" "$k" "$a" "$s" "$au" "$n"
      done
}

# ─────────────────────────────────────────────────────────────────────
# Subcommand: audit
# ─────────────────────────────────────────────────────────────────────

cmd_audit() {
  local chain="${1:-}"
  [[ -n "$chain" ]] || _die "usage: verify-blockscout.sh audit <chain_id>" 2

  local env_check
  env_check="$(_check_audit "$chain")" || exit $?
  local network api web
  IFS=' ' read -r network api web <<<"$env_check"

  _init_log_file audit "$network"
  local out_json="${LOG_FILE%.log}.json"
  _init_summary "$out_json"

  local manifest
  manifest="$(_require_manifest "$chain" "$network")" || exit $?
  _log INFO "Auditing $manifest against $api"

  local rows
  if ! rows="$(_expand_allowlist "$manifest")"; then
    exit 1
  fi

  local failed=0 row addr kind name audit
  while IFS='|' read -r addr kind name; do
    audit="$(_audit_one "$api" "$addr" || true)"
    if [[ "$audit" == "ok" ]]; then
      _log OK "PASS $name @ $addr"
      _emit_row "$out_json" "$name" "$kind" "$addr" "skip" "pass" ""
    else
      failed=$((failed + 1))
      _log ERROR "FAIL $name @ $addr: $audit"
      _emit_row "$out_json" "$name" "$kind" "$addr" "skip" "fail" "$audit"
    fi
  done <<<"$rows"

  local status="pass"
  (( failed > 0 )) && status="fail"
  _finalize_summary "$out_json" "$chain" "$network" "$api" "$web" "$status"
  _publish_latest audit "$network"
  _print_table "$out_json"

  if (( failed > 0 )); then
    _log ERROR "Audit FAILED: $failed of ${#ALLOWLIST[@]} addresses are not verified with expected settings"
    return 1
  fi
  _log OK "Audit PASSED: all ${#ALLOWLIST[@]} addresses verified"
}

# ─────────────────────────────────────────────────────────────────────
# Subcommand: verify
# ─────────────────────────────────────────────────────────────────────

cmd_verify() {
  local chain="${1:-}"
  [[ -n "$chain" ]] || _die "usage: verify-blockscout.sh verify <chain_id>" 2

  local env_check
  env_check="$(_check_rpc "$chain")" || exit $?
  local network rpc api web
  IFS=' ' read -r network rpc api web <<<"$env_check"

  _init_log_file verify "$network"
  local out_json="${LOG_FILE%.log}.json"
  _init_summary "$out_json"

  local manifest
  manifest="$(_require_manifest "$chain" "$network")" || exit $?
  _log INFO "Verifying $manifest"
  _log INFO "  chain=$chain  network=$network"
  _log INFO "  rpc=$rpc"
  _log INFO "  blockscout=$api"

  # Ensure out/ exists (forge build auto-invoke). Quiet on stderr only on success.
  if [[ ! -d out ]]; then
    _log INFO "out/ is missing — running 'forge build --silent'"
    forge build --silent >/dev/null || _die "forge build failed" 1
  fi

  local rows
  if ! rows="$(_expand_allowlist "$manifest")"; then
    exit 1
  fi

  local submitted=0 failed=0 addr kind name target args submit audit note row_ok
  while IFS='|' read -r addr kind name; do
    note=""
    row_ok=1
    target="$(_resolve_source_target "$name")"
    _log INFO "── $name ($kind) @ $addr  →  $target"

    if ! args="$(_extract_constructor_args "$api" "$name" "$addr")"; then
      submit="fail"
      note="args-extract-failed"
      _emit_row "$out_json" "$name" "$kind" "$addr" "$submit" "skip" "$note"
      failed=$((failed + 1))
      continue
    fi

    if _forge_verify "$chain" "$api" "$addr" "$target" "$args"; then
      submit="pass"
      submitted=$((submitted + 1))
    else
      submit="fail"
      row_ok=0
      note="forge-verify-failed"
    fi

    audit="$(_audit_with_lag "$api" "$addr" || true)"
    if [[ "$audit" == "ok" ]]; then
      _log OK "AUDIT PASS $name @ $addr"
      _emit_row "$out_json" "$name" "$kind" "$addr" "$submit" "pass" "$note"
    else
      _log ERROR "AUDIT FAIL $name @ $addr: $audit"
      _emit_row "$out_json" "$name" "$kind" "$addr" "$submit" "fail" "${note:+$note; }$audit"
      row_ok=0
    fi
    (( row_ok )) || failed=$((failed + 1))
  done <<<"$rows"

  local status="pass"
  (( failed > 0 )) && status="fail"
  _finalize_summary "$out_json" "$chain" "$network" "$api" "$web" "$status"
  _publish_latest verify "$network"
  _print_table "$out_json"

  if (( failed > 0 )); then
    _log ERROR "Verify FAILED: $failed issues across ${#ALLOWLIST[@]} targets"
    return 1
  fi
  _log OK "Verify PASSED: $submitted submitted, ${#ALLOWLIST[@]} audited"
}

# ─────────────────────────────────────────────────────────────────────
# Subcommand: verify-one
# ─────────────────────────────────────────────────────────────────────

cmd_verify_one() {
  local chain="${1:-}" addr="${2:-}" name="${3:-}"
  [[ -n "$chain" && -n "$addr" && -n "$name" ]] \
    || _die "usage: verify-blockscout.sh verify-one <chain_id> <address> <contract_name>" 2

  local env_check
  env_check="$(_check_rpc "$chain")" || exit $?
  local network rpc api web
  IFS=' ' read -r network rpc api web <<<"$env_check"

  _init_log_file verify-one "$network"

  if [[ ! -d out ]]; then
    _log INFO "out/ is missing — running 'forge build --silent'"
    forge build --silent >/dev/null || _die "forge build failed" 1
  fi

  local target args
  target="$(_resolve_source_target "$name")"
  _log INFO "Target: $target"

  args="$(_extract_constructor_args "$api" "$name" "$(_lower "$addr")")" \
    || _die "Constructor args extraction failed for $addr" 1
  _log INFO "Constructor args: ${args:-<empty>}"

  _forge_verify "$chain" "$api" "$(_lower "$addr")" "$target" "$args" \
    || _die "forge verify-contract failed for $addr" 1

  local audit
  audit="$(_audit_one "$api" "$(_lower "$addr")" || true)"
  [[ "$audit" == "ok" ]] || _die "audit post-check failed: $audit" 1
  _log OK "verify-one: $name @ $addr is verified"
}

# ─────────────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────────────

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    verify)     cmd_verify "$@" ;;
    audit)      cmd_audit "$@" ;;
    verify-one) cmd_verify_one "$@" ;;
    -h|--help|help|"")
      cat <<'USAGE'
usage: verify-blockscout.sh <subcommand> <args...>

Subcommands:
  verify     <chain_id>                         Full verification of deployments/<net>/retrieval-operator-latest.json
  audit      <chain_id>                         Read-only Blockscout audit (safe for CI, no RPC)
  verify-one <chain_id> <address> <ContractName> Manual single-address fallback

Supported chain_id: 314 (mainnet), 314159 (calibnet)

Environment:
  RPC_MAINNET, RPC_CALIBNET   RPC endpoints (required for verify + verify-one)
  CONFIRM_MAINNET=yes         Required to touch mainnet on any non-audit subcommand
  AUDIT_ALLOW_MAINNET=no      Opts out of mainnet audit (default yes, safe read-only)
  NO_COLOR=1                  Disable ANSI colour codes

Exit codes:
  0 success  1 verification failure  2 usage  3 environment check failure
USAGE
      [[ "$sub" == "" ]] && exit 2 || exit 0
      ;;
    *)
      _die "Unknown subcommand: $sub (use 'help')" 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
