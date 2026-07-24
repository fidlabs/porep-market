#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; tmp="$(mktemp -d)"; trap 'rm -r "$tmp"' EXIT
hash=0x$(printf 'a%.0s' {1..64}); printf '[{"blockNumber":9,"blockHash":"%s"}]\n' "$hash" >"$tmp/blocks.json"
cat >"$tmp/cast" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *ChainGetFinalizedTipSet* ]]; then printf '{"Height":%s}\n' "${HEIGHT:-10}"; else printf '{"number":"0x9","hash":"%s"}\n' "${BLOCK_HASH}"; fi
EOF
chmod +x "$tmp/cast"; export BLOCK_HASH="$hash"
CAST_BIN="$tmp/cast" "$ROOT/script/verify-filecoin-finality.sh" --blocks-json "$tmp/blocks.json" --rpc-url rpc >/dev/null
if HEIGHT=8 CAST_BIN="$tmp/cast" "$ROOT/script/verify-filecoin-finality.sh" --blocks-json "$tmp/blocks.json" --rpc-url rpc 2>/dev/null; then exit 1; fi
if BLOCK_HASH=0x$(printf 'b%.0s' {1..64}) CAST_BIN="$tmp/cast" "$ROOT/script/verify-filecoin-finality.sh" --blocks-json "$tmp/blocks.json" --rpc-url rpc 2>/dev/null; then exit 1; fi
printf 'deployment finality: PASS\n'
