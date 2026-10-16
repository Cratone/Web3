#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

# OpenZeppelin requires build-info from a full compilation, not an incremental one.
forge build --force
node_modules/.bin/openzeppelin-upgrades-core validate out/build-info \
    --contract TripFundV2 --reference TripFundV1 --requireReference
