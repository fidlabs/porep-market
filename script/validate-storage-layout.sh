#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OZ_BIN="${OZ_BIN:-$ROOT/node_modules/.bin/openzeppelin-upgrades-core}"
readonly VERSION=1.46.0
readonly TARGETS=(PoRepMarket ValidatorFactory DataCapEvidenceAdapter SPRegistry SLIOracle SLIScorer Validator)

manifest=''; reference=''; reference_sha=''; current=''; current_sha=''
die() { printf '%s\n' "$1" >&2; exit 1; }
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

while (( $# )); do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    --reference-build-info) reference="$2"; shift 2 ;;
    --reference-sha256) reference_sha="$2"; shift 2 ;;
    --current-build-info) current="$2"; shift 2 ;;
    --current-sha256) current_sha="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$manifest" && -f "$reference" && -f "$current" && -n "$reference_sha" && -n "$current_sha" ]] \
  || die "manifest, two build-info files, and their SHA-256 values are required"
[[ "$(jq -r '.devDependencies["@openzeppelin/upgrades-core"]' "$ROOT/package.json")" == "$VERSION" ]] \
  || die "package.json must pin upgrades-core $VERSION"
[[ "$(jq -r '.packages["node_modules/@openzeppelin/upgrades-core"].version' "$ROOT/package-lock.json")" == "$VERSION" ]] \
  || die "package-lock.json must pin upgrades-core $VERSION"
[[ -x "$OZ_BIN" ]] || die "OpenZeppelin upgrades-core is not executable: $OZ_BIN"
if [[ "$OZ_BIN" == "$ROOT/node_modules/.bin/openzeppelin-upgrades-core" ]]; then
  [[ "$(jq -r .version "$ROOT/node_modules/@openzeppelin/upgrades-core/package.json")" == "$VERSION" ]] \
    || die "installed upgrades-core must be $VERSION"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/storage-layout.XXXXXX")"
trap 'rm -r "$tmp"' EXIT
mkdir "$tmp/reference" "$tmp/current"
gzip -cd "$reference" >"$tmp/reference/build-info.json"
gzip -cd "$current" >"$tmp/current/build-info.json"
[[ "0x$(sha256_file "$tmp/reference/build-info.json")" == "$reference_sha" ]] \
  || die "reference build-info hash does not match"
[[ "0x$(sha256_file "$tmp/current/build-info.json")" == "$current_sha" ]] \
  || die "current build-info hash does not match"

for target in "${TARGETS[@]}"; do
  artifact="src/$target.sol:$target"
  [[ "$(jq -r --arg name "$target" '.contracts[$name].artifact' "$manifest")" == "$artifact" ]] \
    || die "$target artifact does not match manifest"
  args=(validate "$tmp/current" --contract "$artifact" --reference "reference:$artifact" \
    --referenceBuildInfoDirs "$tmp/reference" --requireReference)
  [[ "$target" != DataCapEvidenceAdapter ]] \
    || args+=(--exclude lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol)
  "$OZ_BIN" "${args[@]}" >/dev/null
  printf '%s: valid\n' "$target"
done
