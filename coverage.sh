#!/bin/bash

set -euo pipefail

forge clean
forge build
forge coverage --no-match-coverage "(script)" --ir-minimum --report summary --report lcov
genhtml lcov.info -o report --branch-coverage --ignore-errors inconsistent,corrupt lcov.info
xdg-open report/index.html || open report/index.html
