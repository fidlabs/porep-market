#!/bin/bash

set -euo pipefail

rm -rf abis
mkdir abis

for i in $(find src -name '*.sol'); do
  echo "Generating ABI file for $i"
  i="$(basename "$i")"
  name="${i%.sol}"
  jq .abi <"out/$i/$name.json" >"abis/${name}.json"
done
