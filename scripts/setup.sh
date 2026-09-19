#!/usr/bin/env bash
# Finite, idempotent worktree setup: the pinned tools, the TUI's crates, the
# git hooks. `mise run setup` caches it on its declared sources (the stamp is
# the output), so mise's enter/watch hooks and daft's post-create can all
# call it and it only does work when an input changed.
set -euo pipefail

cd "$(dirname "$0")/.."
mise install
cargo fetch --locked --manifest-path tui/Cargo.toml
# Into the bare repo's SHARED hooks directory: once per clone covers every
# worktree, and re-running refreshes the launcher after a lefthook.yml change.
lefthook install
mkdir -p .build
touch .build/setup.stamp
