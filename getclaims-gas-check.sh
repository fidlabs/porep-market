#!/usr/bin/env bash
set -euo pipefail

RPC_URL="${RPC_URL:-https://api.node.glif.io/rpc/v1}"
INSPECTOR="${INSPECTOR:-0x89C9552Ba6C01c4a7792054f233fd12e6747EC02}"
PROVIDER="${PROVIDER:-2639429}"
PIECE_SIZE_BYTES="${PIECE_SIZE_BYTES:-34359738368}"
COUNTS="${COUNTS:-1498 1550 1600 1650 1686 1687}"
GAS_LIMITS="${GAS_LIMITS:-20000000000 30000000000}"
MAX_CLAIMS="${MAX_CLAIMS:-5000}"
OUT="${OUT:-getclaims-gas-check-run.csv}"
CLAIM_IDS_FILE="${CLAIM_IDS_FILE:-}"

require() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "missing required command: $1" >&2
        exit 1
    fi
}

dec_to_hex() {
    printf '0x%x' "$1"
}

json_escape_csv_row() {
    jq -rn \
        --arg timestamp "$1" \
        --arg rpc_url "$2" \
        --arg inspector "$3" \
        --arg provider "$4" \
        --arg piece_size_bytes "$5" \
        --arg count "$6" \
        --arg total_bytes "$7" \
        --arg gas_limit "$8" \
        --arg gas_hex "$9" \
        --arg calldata_bytes "${10}" \
        --arg status "${11}" \
        --arg result_hex_chars "${12}" \
        --arg error_message "${13}" \
        --arg first_claim "${14}" \
        --arg last_claim "${15}" \
        '[
            $timestamp,
            $rpc_url,
            $inspector,
            $provider,
            $piece_size_bytes,
            $count,
            $total_bytes,
            $gas_limit,
            $gas_hex,
            $calldata_bytes,
            $status,
            $result_hex_chars,
            $error_message,
            $first_claim,
            $last_claim
        ] | @csv'
}

fetch_claim_ids() {
    local response
    response="$(mktemp)"
    curl -s "$RPC_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"method\":\"Filecoin.StateGetClaims\",\"params\":[\"t0${PROVIDER}\",null],\"id\":1}" \
        >"$response"

    if jq -e '.error? != null' "$response" >/dev/null; then
        jq -r '.error.message' "$response" >&2
        rm -f "$response"
        exit 1
    fi

    jq -r \
        --argjson size "$PIECE_SIZE_BYTES" \
        --argjson max "$MAX_CLAIMS" \
        '.result
         | to_entries
         | map(select(.value.Size == $size))
         | sort_by(.key | tonumber)
         | .[0:$max]
         | map(.key)
         | join(",")' \
        "$response"

    rm -f "$response"
}

ids_for_count() {
    local count="$1"
    awk -F, -v n="$count" '{
        for (i = 1; i <= n && i <= NF; i++) {
            printf "%s%s", (i == 1 ? "" : ","), $i
        }
    }' "$CLAIM_IDS_FILE"
}

claim_at() {
    local index="$1"
    awk -F, -v n="$index" '{print $n}' "$CLAIM_IDS_FILE"
}

require curl
require jq
require cast
require awk

if [ -z "$CLAIM_IDS_FILE" ]; then
    CLAIM_IDS_FILE="$(mktemp)"
    fetch_claim_ids >"$CLAIM_IDS_FILE"
else
    if [ ! -f "$CLAIM_IDS_FILE" ]; then
        echo "CLAIM_IDS_FILE does not exist: $CLAIM_IDS_FILE" >&2
        exit 1
    fi
fi

available_claims="$(awk -F, '{print NF}' "$CLAIM_IDS_FILE")"
first_claim="$(claim_at 1)"
last_available_claim="$(claim_at "$available_claims")"

{
    echo "timestamp,rpc_url,inspector,provider,piece_size_bytes,count,total_bytes,gas_limit,gas_hex,calldata_bytes,status,result_hex_chars,error_message,first_claim,last_claim"
} >"$OUT"

echo "rpc_url=$RPC_URL"
echo "inspector=$INSPECTOR"
echo "provider=$PROVIDER"
echo "piece_size_bytes=$PIECE_SIZE_BYTES"
echo "available_filtered_claims=$available_claims"
echo "first_claim=$first_claim"
echo "last_available_claim=$last_available_claim"
echo "counts=$COUNTS"
echo "gas_limits=$GAS_LIMITS"
echo "out=$OUT"

for gas_limit in $GAS_LIMITS; do
    gas_hex="$(dec_to_hex "$gas_limit")"
    for count in $COUNTS; do
        if [ "$count" -gt "$available_claims" ]; then
            echo "skip count=$count: only $available_claims filtered claims available" >&2
            continue
        fi

        ids="$(ids_for_count "$count")"
        data="$(cast calldata "getClaimsForProvider(uint64,uint64[])" "$PROVIDER" "[$ids]")"
        calldata_bytes="$(((${#data} - 2) / 2))"
        total_bytes="$((count * PIECE_SIZE_BYTES))"
        last_claim="$(claim_at "$count")"
        timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        payload="$(jq -nc \
            --arg to "$INSPECTOR" \
            --arg gas "$gas_hex" \
            --arg data "$data" \
            '{jsonrpc:"2.0",method:"eth_call",params:[{to:$to,gas:$gas,data:$data},"latest"],id:1}')"

        response="$(curl -s "$RPC_URL" -H 'Content-Type: application/json' -d "$payload")"

        if jq -e '.error? != null' <<<"$response" >/dev/null; then
            status="ERROR"
            result_hex_chars=""
            error_message="$(jq -r '.error.message' <<<"$response" | tr '\n' ' ')"
        else
            status="OK"
            result_hex_chars="$(jq -r '.result | length' <<<"$response")"
            error_message=""
        fi

        json_escape_csv_row \
            "$timestamp" \
            "$RPC_URL" \
            "$INSPECTOR" \
            "$PROVIDER" \
            "$PIECE_SIZE_BYTES" \
            "$count" \
            "$total_bytes" \
            "$gas_limit" \
            "$gas_hex" \
            "$calldata_bytes" \
            "$status" \
            "$result_hex_chars" \
            "$error_message" \
            "$first_claim" \
            "$last_claim" \
            >>"$OUT"

        echo "gas=$gas_limit count=$count status=$status calldata_bytes=$calldata_bytes result_hex_chars=${result_hex_chars:-0}"
    done
done
