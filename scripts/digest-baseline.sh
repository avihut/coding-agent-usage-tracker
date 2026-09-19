#!/usr/bin/env bash
# Exports a ref's digest goldens to a temp directory and prints its path —
# the input of the digest freeze tests (DigestFreezeTests.swift, and
# `baseline_goldens_decode` in tui/src/digest.rs), which read it from
# DIGEST_BASELINE_DIR.
#
# Why: the goldens are regenerated in place, so on any one branch the code
# and its golden always agree — a breaking schema change plus
# UPDATE_GOLDENS=1 passes both suites. Only the OTHER side of a merge still
# holds the old golden, so the merge gate is where "additive-only forever"
# can actually be checked: the branch's decoders read main's golden, and
# every key main's golden carries is still on the wire.
#
#   DIGEST_BASELINE_DIR="$(scripts/digest-baseline.sh main)" mise run check
set -euo pipefail

# daft runs merge hooks, and a hook may run inside a git hook, where an
# inherited GIT_DIR would retarget the commands below. The cwd is the truth.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

ref="${1:?usage: digest-baseline.sh <ref>}"
goldens=Tests/UsageCoreTests/Fixtures/digest

cd "$(git rev-parse --show-toplevel)"
git rev-parse -q --verify "$ref^{commit}" >/dev/null || {
    echo "digest-baseline: '$ref' is not a commit" >&2
    exit 1
}

out=$(mktemp -d "${TMPDIR:-/tmp}/digest-baseline.XXXXXX")
# A ref from before the goldens existed exports nothing, and the freeze
# tests then have nothing to hold the branch to — which is the truth.
git ls-tree --name-only "$ref:$goldens" 2>/dev/null | while IFS= read -r name; do
    case "$name" in
    *.json) git show "$ref:$goldens/$name" >"$out/$name" ;;
    esac
done
echo "$out"
