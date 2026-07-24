#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OZ_BIN="$ROOT/node_modules/.bin/openzeppelin-upgrades-core"

manifest=''; reference=''; reference_sha=''; current=''; current_sha=''; targets=()
die() { printf '%s\n' "$1" >&2; exit 1; }
sha256_file() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

while (( $# )); do
  case "$1" in
    --manifest) manifest="$2"; shift 2 ;;
    --target) targets+=("$2"); shift 2 ;;
    --reference-build-info) reference="$2"; shift 2 ;;
    --reference-sha256) reference_sha="$2"; shift 2 ;;
    --current-build-info) current="$2"; shift 2 ;;
    --current-sha256) current_sha="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -f "$manifest" && -f "$reference" && -f "$current" && -n "$reference_sha" && -n "$current_sha" && ${#targets[@]} -gt 0 ]] \
  || die "manifest, targets, two build-info files, and their SHA-256 values are required"
[[ -x "$OZ_BIN" ]] || die "OpenZeppelin upgrades-core is not executable: $OZ_BIN"
expected_version="$(jq -er '.devDependencies["@openzeppelin/upgrades-core"] | select(type=="string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$ROOT/package.json")" \
  || die "package.json must pin upgrades-core to an exact version"
[[ "$(jq -r .version "$ROOT/node_modules/@openzeppelin/upgrades-core/package.json")" == "$expected_version" ]] \
  || die "installed upgrades-core must be $expected_version"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/storage-layout.XXXXXX")"
trap 'rm -r "$tmp"' EXIT
mkdir "$tmp/reference" "$tmp/current"
gzip -cd "$reference" >"$tmp/reference/build-info.json"
gzip -cd "$current" >"$tmp/current/build-info.json"
[[ "0x$(sha256_file "$tmp/reference/build-info.json")" == "$reference_sha" ]] \
  || die "reference build-info hash does not match"
[[ "0x$(sha256_file "$tmp/current/build-info.json")" == "$current_sha" ]] \
  || die "current build-info hash does not match"

for target in "${targets[@]}"; do
  artifact="$(jq -er --arg name "$target" '.contracts[$name].artifact | select(type=="string" and length>0)' "$manifest")" \
    || die "$target artifact is invalid in manifest"
  args=(validate "$tmp/current" --contract "$artifact" --reference "reference:$artifact" \
    --referenceBuildInfoDirs "$tmp/reference" --requireReference)
  [[ "$target" != DataCapEvidenceAdapter ]] \
    || args+=(--exclude lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol)
  "$OZ_BIN" "${args[@]}" >/dev/null
  printf '%s: valid\n' "$target"
done
