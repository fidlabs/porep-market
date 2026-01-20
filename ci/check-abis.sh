#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")"/..

for i in $(find src -name '*.sol' ! -path "*/interfaces/*"); do
  i="$(basename "$i")"
  name="${i%.sol}"
  [ -f "abis/${name}.json" ] || exit 1
  { jq .abi <"out/$i/$name.json" | diff - "abis/${name}.json" >/dev/null; } || exit 1
done
