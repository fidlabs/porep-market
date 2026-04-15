#!/bin/bash
#
# PoRep Market — mainnet deployment preflight checks.
#
# Pure preflight: no side effects, no broadcasts, no file writes.
# Called by `just mainnet_deploy` / `mainnet_upgrade` / `mainnet_deploy_dry`
# before `forge script` runs.
#
# Modes:
#   deploy     Full gate package for `just mainnet_deploy`
#   upgrade    Gates for `just mainnet_upgrade`
#   dry        Minimal gates for `just mainnet_deploy_dry`
#
# Exit codes:
#   0  all gates passed
#   2  usage error
#   3  gate failure
#
# Operator runbook: docs/howto/2026-04-15-mainnet-deploy.md

set -euo pipefail
IFS=$'\n\t'

cd "$(dirname "$0")/.."

# ─────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────

readonly EXPECTED_CHAIN_ID="314"
readonly MAINNET_MANIFEST="deployments/mainnet/latest.json"

readonly REQUIRED_DEPLOY_VARS=(
  PRIVATE_KEY_MAINNET
  FILECOIN_PAY_MAINNET
  TERMINATION_ORACLE_MAINNET
  ORACLE_MAINNET
  POREP_SERVICE_MAINNET
  META_ALLOCATOR_MAINNET
)

readonly REQUIRED_UPGRADE_VARS=(
  PRIVATE_KEY_MAINNET
  UPGRADE_CONTRACT_NAME
)

# ─────────────────────────────────────────────────────────────────────
# Logging (mirrors script/verify-blockscout.sh for operator muscle memory)
# ─────────────────────────────────────────────────────────────────────

COLOR_ENABLED=1
[[ -t 2 ]] || COLOR_ENABLED=0
[[ "${NO_COLOR:-}" == "" ]] || COLOR_ENABLED=0

_log() {
  local level="$1"; shift
  local ts color reset=''
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
  printf '%s[%s] %-5s %s%s\n' "$color" "$ts" "$level" "$*" "$reset" >&2
}

_die() {
  _log ERROR "$1"
  exit "${2:-3}"
}

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
# Gates
# ─────────────────────────────────────────────────────────────────────

_gate_confirm_mainnet() {
  [[ "${CONFIRM_MAINNET:-}" == "yes" ]] \
    || _die "CONFIRM_MAINNET=yes is required for mainnet operations"
}

_gate_chain_id() {
  local rpc="${RPC_MAINNET:-}"
  [[ -n "$rpc" ]] || _die "RPC_MAINNET is empty or unset"
  command -v cast >/dev/null 2>&1 || _die "cast is not in PATH"

  local actual
  actual="$(_retry 3 cast chain-id --rpc-url "$rpc")" \
    || _die "RPC_MAINNET is unreachable"
  [[ "$actual" == "$EXPECTED_CHAIN_ID" ]] \
    || _die "RPC_MAINNET points at chain $actual, expected $EXPECTED_CHAIN_ID"
}

_gate_clean_tree() {
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    if [[ "${ALLOW_DIRTY_TREE:-}" == "yes" ]]; then
      _log WARN "git tree is dirty (ALLOW_DIRTY_TREE=yes override in effect)"
      return 0
    fi
    _die "git tree is dirty — verification invariant requires a clean tree (use ALLOW_DIRTY_TREE=yes to override, see runbook)"
  fi
}

_gate_no_manifest() {
  if [[ -f "$MAINNET_MANIFEST" ]]; then
    if [[ "${ALLOW_REDEPLOY:-}" == "yes" ]]; then
      _log WARN "$MAINNET_MANIFEST already exists (ALLOW_REDEPLOY=yes override in effect)"
      return 0
    fi
    _die "$MAINNET_MANIFEST already exists — use 'just mainnet_upgrade' for impl changes, or ALLOW_REDEPLOY=yes to force a full redeploy"
  fi
}

_gate_required_vars() {
  local varname
  for varname in "$@"; do
    if [[ -z "${!varname:-}" ]]; then
      _die "required env var $varname is not set"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────
# Summary output
# ─────────────────────────────────────────────────────────────────────

_print_deploy_summary() {
  local mode="$1"
  _log OK "preflight passed (mode=$mode chain=$EXPECTED_CHAIN_ID)"
  printf '              %-27s = %s\n' "FILECOIN_PAY_MAINNET"       "$FILECOIN_PAY_MAINNET"       >&2
  printf '              %-27s = %s\n' "TERMINATION_ORACLE_MAINNET" "$TERMINATION_ORACLE_MAINNET" >&2
  printf '              %-27s = %s\n' "ORACLE_MAINNET"             "$ORACLE_MAINNET"             >&2
  printf '              %-27s = %s\n' "POREP_SERVICE_MAINNET"      "$POREP_SERVICE_MAINNET"      >&2
  printf '              %-27s = %s\n' "META_ALLOCATOR_MAINNET"     "$META_ALLOCATOR_MAINNET"     >&2
  if [[ -n "${OPERATOR_ADDR_MAINNET:-}" ]]; then
    printf '              %-27s = %s\n' "OPERATOR_ADDR_MAINNET" "$OPERATOR_ADDR_MAINNET" >&2
  else
    printf '              %-27s = (unset, skipping OPERATOR_ROLE grant)\n' "OPERATOR_ADDR_MAINNET" >&2
  fi
  printf '              %-27s = %s\n' "RPC_MAINNET" "$RPC_MAINNET" >&2
}

_print_upgrade_summary() {
  _log OK "preflight passed (mode=upgrade chain=$EXPECTED_CHAIN_ID)"
  printf '              %-27s = %s\n' "UPGRADE_CONTRACT_NAME" "$UPGRADE_CONTRACT_NAME" >&2
  printf '              %-27s = %s\n' "UPGRADE_CALLDATA"      "${UPGRADE_CALLDATA:-0x}" >&2
  printf '              %-27s = %s\n' "RPC_MAINNET"           "$RPC_MAINNET" >&2
}

# ─────────────────────────────────────────────────────────────────────
# Mode commands
# ─────────────────────────────────────────────────────────────────────

cmd_deploy() {
  _gate_confirm_mainnet
  _gate_chain_id
  _gate_clean_tree
  _gate_no_manifest
  _gate_required_vars "${REQUIRED_DEPLOY_VARS[@]}"
  _print_deploy_summary deploy
}

cmd_upgrade() {
  _gate_confirm_mainnet
  _gate_chain_id
  _gate_clean_tree
  _gate_required_vars "${REQUIRED_UPGRADE_VARS[@]}"
  _print_upgrade_summary
}

cmd_dry() {
  _gate_chain_id
  _gate_required_vars "${REQUIRED_DEPLOY_VARS[@]}"
  _print_deploy_summary dry
}

# ─────────────────────────────────────────────────────────────────────
# Entrypoint
# ─────────────────────────────────────────────────────────────────────

main() {
  local mode="${1:-}"
  case "$mode" in
    deploy)  cmd_deploy ;;
    upgrade) cmd_upgrade ;;
    dry)     cmd_dry ;;
    -h|--help|help)
      _print_usage
      exit 0
      ;;
    "")
      _print_usage
      exit 2
      ;;
    *)
      _log ERROR "unknown mode: $mode (use 'deploy', 'upgrade', or 'dry')"
      _print_usage
      exit 2
      ;;
  esac
}

_print_usage() {
  cat >&2 <<'USAGE'
usage: preflight-mainnet.sh <mode>

Modes:
  deploy    Full gate package for `just mainnet_deploy`
  upgrade   Gates for `just mainnet_upgrade`
  dry       Minimal gates for `just mainnet_deploy_dry`

Exit codes:
  0  all gates passed
  2  usage error
  3  gate failure
USAGE
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
