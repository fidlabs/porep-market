#!/usr/bin/env bash

set -euo pipefail
CAST_BIN="${CAST_BIN:-cast}"
readonly IMPLEMENTATION_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
readonly UUPS=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer)
die() { printf '%s\n' "$1" >&2; exit 1; }
lower() { tr '[:upper:]' '[:lower:]'; }
address() { local v; v="$(printf '%s' "$1" | lower)"; [[ "$v" =~ ^0x[0-9a-f]{64}$ ]] && v="0x${v: -40}"; [[ "$v" =~ ^0x[0-9a-f]{40}$ ]] || return 1; printf %s "$v"; }
runtime_code() { local code; code="$($CAST_BIN rpc --rpc-url "$rpc" eth_getCode "$1" latest | jq -er 'select(test("^0x([0-9a-fA-F]{2})*$"))')" || die "could not read $2 runtime bytecode"; [[ "$code" != 0x ]] || die "$2 has no runtime bytecode"; printf %s "$code"; }
runtime() { runtime_code "$1" "$2" >/dev/null; }
runtime_hash() { local code; code="$(runtime_code "$1" "$2")" || return 1; "$CAST_BIN" keccak "$code"; }
call_address() { local got expected; got="$(address "$($CAST_BIN call "$1" "$2" --rpc-url "$rpc")")" || die "could not read $4"; expected="$(printf '%s' "$3" | lower)"; [[ "$got" == "$expected" ]] || die "$4 does not match manifest"; }
role() { local id result; id="$($CAST_BIN call "$1" "$2" --rpc-url "$rpc")"; result="$($CAST_BIN call "$1" 'hasRole(bytes32,address)(bool)' "$id" "$3" --rpc-url "$rpc" | tr -d '[:space:]')"; [[ "$result" == true ]] || die "$4 role is missing"; }
manifest=''; operations=''; rpc=''
while (( $# )); do case "$1" in
  --manifest) manifest="$2"; shift 2 ;; --operations) operations="$2"; shift 2 ;; --rpc-url) rpc="$2"; shift 2 ;;
  *) die "usage: deployment-live-checks.sh --manifest <file> [--operations <file>] --rpc-url <url>" ;;
esac; done
[[ -f "$manifest" && -n "$rpc" ]] || die "manifest and RPC URL are required"
for name in "${UUPS[@]}"; do
  proxy="$(jq -r ".contracts.$name.proxy" "$manifest")"; expected="$(jq -r ".contracts.$name.implementation" "$manifest")"
  [[ -z "$operations" ]] || replacement="$(jq -r --arg n "$name" '[.[]|select(.target==$n)][-1].newImplementation // empty' "$operations")"
  [[ -z "${replacement:-}" ]] || { expected="$replacement"; hash="$(jq -r --arg n "$name" '[.[]|select(.target==$n)][-1].newImplementationCodeHash // empty' "$operations")"; code_hash="$(runtime_hash "$replacement" "$name replacement")"; [[ "$(printf '%s' "$code_hash" | lower)" == "$(printf '%s' "$hash" | lower)" ]] || die "$name replacement code hash does not match"; }
  runtime "$proxy" "$name proxy"; runtime "$expected" "$name implementation"
  actual="$(address "$($CAST_BIN rpc --rpc-url "$rpc" eth_getStorageAt "$proxy" "$IMPLEMENTATION_SLOT" latest | jq -er 'select(test("^0x[0-9a-fA-F]{64}$"))')")"
  [[ "$actual" == "$(printf '%s' "$expected" | lower)" ]] || die "$name implementation slot does not match"
done
beacon="$(jq -r .contracts.ValidatorBeacon.address "$manifest")"; validator="$(jq -r .contracts.Validator.implementation "$manifest")"
[[ -z "$operations" ]] || replacement="$(jq -r '[.[]|select(.target=="Validator")][-1].newImplementation // empty' "$operations")"
[[ -z "${replacement:-}" ]] || { validator="$replacement"; hash="$(jq -r '[.[]|select(.target=="Validator")][-1].newImplementationCodeHash // empty' "$operations")"; code_hash="$(runtime_hash "$replacement" "Validator replacement")"; [[ "$(printf '%s' "$code_hash" | lower)" == "$(printf '%s' "$hash" | lower)" ]] || die "Validator replacement code hash does not match"; }
runtime "$beacon" 'ValidatorBeacon'; runtime "$validator" 'Validator implementation'
call_address "$beacon" 'implementation()(address)' "$validator" 'ValidatorBeacon implementation'
call_address "$beacon" 'owner()(address)' "$(jq -r .deployer "$manifest")" 'ValidatorBeacon owner'
factory="$(jq -r .contracts.ValidatorFactory.proxy "$manifest")"
call_address "$factory" 'getBeacon()(address)' "$beacon" 'ValidatorFactory beacon'
for name in "${UUPS[@]}"; do role "$(jq -r ".contracts.$name.proxy" "$manifest")" 'DEFAULT_ADMIN_ROLE()(bytes32)' "$(jq -r .deployer "$manifest")" "$name admin"; done
role "$(jq -r .contracts.PoRepMarket.proxy "$manifest")" 'POREP_SERVICE_ROLE()(bytes32)' "$(jq -r .externalDependencies.PoRepService "$manifest")" 'PoRep service'
role "$(jq -r .contracts.SLIOracle.proxy "$manifest")" 'ORACLE_ROLE()(bytes32)' "$(jq -r .externalDependencies.Oracle "$manifest")" 'SLI oracle'
role "$(jq -r .contracts.DataCapEvidenceAdapter.proxy "$manifest")" 'TERMINATION_ORACLE()(bytes32)' "$(jq -r .externalDependencies.TerminationOracle "$manifest")" 'termination oracle'
role "$(jq -r .contracts.SPRegistry.proxy "$manifest")" 'MARKET_ROLE()(bytes32)' "$(jq -r .contracts.PoRepMarket.proxy "$manifest")" 'registry market'
operator="$(jq -r .externalDependencies.Operator "$manifest")"
[[ "$operator" == 0x0000000000000000000000000000000000000000 ]] || role "$(jq -r .contracts.SPRegistry.proxy "$manifest")" 'OPERATOR_ROLE()(bytes32)' "$operator" 'SP operator'
call_address "$(jq -r .contracts.PoRepMarket.proxy "$manifest")" 'getValidatorFactoryContract()(address)' "$factory" 'market validator factory'
call_address "$(jq -r .contracts.PoRepMarket.proxy "$manifest")" 'getSPRegistryContract()(address)' "$(jq -r .contracts.SPRegistry.proxy "$manifest")" 'market SP registry'
call_address "$(jq -r .contracts.DataCapEvidenceAdapter.proxy "$manifest")" 'getPoRepMarketAddress()(address)' "$(jq -r .contracts.PoRepMarket.proxy "$manifest")" 'adapter market'
runtime "$(jq -r .externalDependencies.FilecoinPay "$manifest")" 'FilecoinPay'
runtime "$(jq -r .externalDependencies.MetaAllocator "$manifest")" 'MetaAllocator'
