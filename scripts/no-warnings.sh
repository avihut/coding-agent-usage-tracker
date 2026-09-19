#!/usr/bin/env bash
# Runs a command and fails if it printed a warning, even when it exited 0.
# `-warnings-as-errors` and `-D warnings` only cover what the COMPILER
# diagnoses; the linker (`ld: warning:`), SwiftPM and cargo warn outside
# their reach, and a gate that says "builds without warnings" means those
# too. The command's own failure passes through (pipefail).
#
#   scripts/no-warnings.sh <command> [args…]
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/.build"
log=$(mktemp "$root/.build/no-warnings.XXXXXX")
trap 'rm -f "$log"' EXIT

"$@" 2>&1 | tee "$log"
if grep -Eiq '(^|[[:space:]])warning:' "$log"; then
    echo "no-warnings: the command succeeded but printed warnings — fix the diagnostics above" >&2
    exit 1
fi
