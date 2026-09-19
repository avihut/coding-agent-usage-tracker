#!/usr/bin/env bash
# The gate's own configuration parses: a typo in lefthook.yml, daft.yml or
# mise.toml otherwise surfaces as a hook that silently doesn't run.
set -euo pipefail

cd "$(dirname "$0")/.."
lefthook validate
daft hooks validate
mise tasks validate
plutil -lint Support/Info.plist
