#!/usr/bin/env bash

set -euo pipefail
CAST_BIN="${CAST_BIN:-cast}"
blocks=''; rpc=''
die() { printf '%s\n' "$1" >&2; exit 1; }
while (( $# )); do case "$1" in
  --blocks-json) blocks="$2"; shift 2 ;; --rpc-url) rpc="$2"; shift 2 ;;
  *) die "usage: verify-filecoin-finality.sh --blocks-json <file> --rpc-url <url>" ;;
esac; done
[[ -f "$blocks" && -n "$rpc" ]] || die "blocks JSON and RPC URL are required"
jq -e 'type=="array" and length>0 and all(.[];.blockNumber>0 and (.blockHash|test("^0x[0-9a-fA-F]{64}$")))' "$blocks" >/dev/null \
  || die "invalid receipt blocks"
finalized="$($CAST_BIN rpc --rpc-url "$rpc" Filecoin.ChainGetFinalizedTipSet | jq -er '.Height|select(type=="number")')" \
  || die "could not read Filecoin finalized height"
while IFS=$'\t' read -r height expected; do
  (( height <= finalized )) || die "receipt block $height is above Filecoin finalized height $finalized"
  printf -v quantity '0x%x' "$height"
  block="$($CAST_BIN rpc --rpc-url "$rpc" eth_getBlockByNumber "$quantity" false)" \
    || die "could not read canonical block $height"
  actual_height="$(jq -er '.number|select(test("^0x[0-9a-fA-F]+$"))' <<<"$block")"
  actual_hash="$(jq -er '.hash|ascii_downcase|select(test("^0x[0-9a-f]{64}$"))' <<<"$block")"
  (( actual_height == height )) || die "canonical block height mismatch for $height"
  [[ "$actual_hash" == "$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')" ]] || die "receipt block $height is not canonical"
done < <(jq -r 'unique_by(.blockNumber)[]|[.blockNumber,.blockHash]|@tsv' "$blocks")
printf 'Filecoin finalized height %s covers all receipt blocks\n' "$finalized"
