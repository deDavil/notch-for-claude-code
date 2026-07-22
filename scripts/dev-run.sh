#!/usr/bin/env bash
# Run the notch app from source with a virtual notch (for the no-notch dev Mac).
set -euo pipefail
cd "$(dirname "$0")/.."
export NOTCH_VIRTUAL=1
exec swift run NotchApp "$@"
