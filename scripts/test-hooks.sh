#!/usr/bin/env bash
# Tests for the hook scripts themselves: every pass path AND every refusal,
# in a throwaway repository. A gate nobody has seen fail is a gate nobody
# knows works. Touches nothing of this repository's index or refs, no
# network, no credentials, no signing.
set -euo pipefail

scripts=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$scripts")
mkdir -p "$root/.build"
tmp=$(mktemp -d "$root/.build/test-hooks.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
out="$tmp/output.log"
checks=0

# git may have exported these when this runs inside a hook.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

passes() {
    if ! "$@" >"$out" 2>&1; then
        cat "$out" >&2
        echo "test-hooks: expected SUCCESS: $*" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
fails() {
    if "$@" >"$out" 2>&1; then
        cat "$out" >&2
        echo "test-hooks: expected a REFUSAL: $*" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
# `with_stdin <text> <command…>` — for the pre-push check, which reads refs.
with_stdin() {
    local input=$1
    shift
    printf '%s' "$input" | "$@"
}

# ── no-warnings.sh ──────────────────────────────────────────────────────────
passes "$scripts/no-warnings.sh" /bin/sh -c 'echo clean'
fails "$scripts/no-warnings.sh" /bin/sh -c 'exit 7'
fails "$scripts/no-warnings.sh" /bin/sh -c 'echo "warning: package diagnostic" >&2'
fails "$scripts/no-warnings.sh" /bin/sh -c 'echo "ld: warning: linker diagnostic"'

# ── a fixture shaped like this repository ───────────────────────────────────
repo="$tmp/repo"
mkdir -p "$repo" "$tmp/no-hooks"
cd "$repo"
git init -q -b main .
git config user.name "Hook tests"
git config user.email "hooks@example.invalid"
git config commit.gpgsign false
git config tag.gpgsign false
git config core.hooksPath "$tmp/no-hooks"

set_version() {
    mkdir -p Sources/UsageCore
    printf 'public enum AppIdentity {\n    public static let version = "%s"\n}\n' "$1" \
        >Sources/UsageCore/AppIdentity.swift
}
mkdir -p scripts tui/src Tests/UsageCoreTests/Fixtures/digest
cp "$root/cog.toml" .
set_version 0.1.0
printf 'let package = Package(name: "fixture")\n' >Package.swift
printf '[package]\nname = "fixture"\n\n[dependencies]\nserde = "1"\n' >tui/Cargo.toml
printf '[tasks.tool]\nrun = "scripts/tool.sh"\n' >mise.toml
printf '#!/bin/sh\n' >scripts/tool.sh
printf 'let status = "https://status.claude.com/api"\n' >Sources/UsageCore/Links.swift
printf '{"schemaVersion":1}\n' >Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json
git add -A
git commit -qm 'chore: fixture'
base=$(git rev-parse HEAD)

# ── guard.sh ────────────────────────────────────────────────────────────────
passes "$scripts/guard.sh"
passes "$scripts/guard.sh" --staged

# Each rule trips on its own, and the tree is restored after.
trips() { # trips <file> <content to append>
    printf '%s\n' "$2" >>"$1"
    git add -A
    fails "$scripts/guard.sh"
    fails "$scripts/guard.sh" --staged
    git reset -q --hard "$base"
    git clean -qfd
}
# Assembled at run time so this file never holds a token-shaped string.
trips Tests/UsageCoreTests/Fixtures/real.json "\"token\": \"sk-ant-$(printf 'oat01')-AbCdEfGhIjKlMnOp\""
trips scripts/tool.sh "# $(printf 'Developer ID Application'): Some Person (ABCDE12345)"
trips Package.swift 'dependencies: [.package(url: "x", from: "1.0.0")]'
trips tui/Cargo.toml 'tokio = "1"'
trips Sources/UsageCore/Links.swift 'let beacon = "https://telemetry.example.com/collect"'
printf '#!/bin/sh\n' >scripts/orphan.sh
git add -A
fails "$scripts/guard.sh" --staged
git reset -q --hard "$base"

# --staged reads the INDEX: a violation staged and then fixed only in the
# working tree is still what the commit would record.
printf 'let beacon = "https://telemetry.example.com/collect"\n' >>Sources/UsageCore/Links.swift
git add -A
git show "$base:Sources/UsageCore/Links.swift" >Sources/UsageCore/Links.swift
passes "$scripts/guard.sh"
fails "$scripts/guard.sh" --staged
git reset -q --hard "$base"

# ── commit-msg.sh ───────────────────────────────────────────────────────────
msg="$tmp/message with spaces.txt"
subject() { printf '%s\n' "$1" >"$msg"; }
subject 'feat(menubar): a cell per harness' && passes "$scripts/commit-msg.sh" "$msg"
subject 'fixup! feat: adjust the panel' && passes "$scripts/commit-msg.sh" "$msg"
subject 'a subject with no type' && fails "$scripts/commit-msg.sh" "$msg"
subject 'menubar: an area is a scope, not a type' && fails "$scripts/commit-msg.sh" "$msg"
subject 'release: v0.1.0' && passes "$scripts/commit-msg.sh" "$msg"
subject 'release: v0.2.0' && fails "$scripts/commit-msg.sh" "$msg"
subject 'release: the big one' && fails "$scripts/commit-msg.sh" "$msg"
# A commit that moves the version must BE the release commit for it.
set_version 0.2.0
git add -A
subject 'fix: a bump smuggled into a fix' && fails "$scripts/commit-msg.sh" "$msg"
subject 'release: v0.2.0' && passes "$scripts/commit-msg.sh" "$msg"
git commit -qm 'release: v0.2.0'
release=$(git rev-parse HEAD)

# ── release-check.sh (pre-push stdin: local ref, sha, remote ref, sha) ──────
zero=0000000000000000000000000000000000000000
branch_push="refs/heads/main $release refs/heads/main $base
"
fails with_stdin "$branch_push" "$scripts/release-check.sh" # no tag yet
git tag v0.2.0 "$release"                                   # lightweight
fails with_stdin "$branch_push" "$scripts/release-check.sh"
fails with_stdin "refs/tags/v0.2.0 $release refs/tags/v0.2.0 $zero
" "$scripts/release-check.sh"
git tag -d v0.2.0 >/dev/null
git tag -a v0.2.0 -m 'notes' "$base" # annotated, wrong commit
fails with_stdin "$branch_push" "$scripts/release-check.sh"
git tag -d v0.2.0 >/dev/null
git tag -a v0.2.0 -m 'notes' "$release"
passes with_stdin "$branch_push" "$scripts/release-check.sh"
passes with_stdin "${branch_push}refs/tags/v0.2.0 $(git rev-parse v0.2.0) refs/tags/v0.2.0 $zero
" "$scripts/release-check.sh"
passes with_stdin "(delete) $zero refs/heads/gone $base
" "$scripts/release-check.sh"
passes with_stdin "" "$scripts/release-check.sh"
git tag -a v0.9.0 -m 'notes' "$release" # a tag whose version the tree doesn't hold
fails with_stdin "refs/tags/v0.9.0 $(git rev-parse v0.9.0) refs/tags/v0.9.0 $zero
" "$scripts/release-check.sh"
git tag -d v0.9.0 >/dev/null

# ── release-reminder.sh ─────────────────────────────────────────────────────
passes "$scripts/release-reminder.sh" # HEAD is the tagged release
git commit -q --allow-empty -m 'docs: not a release-worthy change'
passes "$scripts/release-reminder.sh"
git commit -q --allow-empty -m 'fix(panel): something users would notice'
fails "$scripts/release-reminder.sh"
git checkout -q -b topic
passes "$scripts/release-reminder.sh" # releases are cut from main only

# ── merge-commits.sh ────────────────────────────────────────────────────────
fails env -u DAFT_MERGE_TARGET_BRANCH "$scripts/merge-commits.sh"
git commit -q --allow-empty -m 'test: a conventional incoming commit'
passes env DAFT_MERGE_TARGET_BRANCH=main "$scripts/merge-commits.sh"
git commit -q --allow-empty -m 'written with --no-verify'
fails env DAFT_MERGE_TARGET_BRANCH=main "$scripts/merge-commits.sh"

# ── landed-check.sh ─────────────────────────────────────────────────────────
head=$(git rev-parse HEAD)
passes env DAFT_MERGE_RESULT=success DAFT_MERGE_SOURCE_SHAS="$head" "$scripts/landed-check.sh"
# An inherited GIT_DIR must not retarget it.
passes env DAFT_MERGE_RESULT=success DAFT_MERGE_SOURCE_SHAS="$head" GIT_DIR="$root/.git" "$scripts/landed-check.sh"
fails env DAFT_MERGE_RESULT=success DAFT_MERGE_SOURCE_SHAS="$base" "$scripts/landed-check.sh"
passes env DAFT_MERGE_RESULT=conflict DAFT_MERGE_SOURCE_SHAS="$base" "$scripts/landed-check.sh"
fails env -u DAFT_MERGE_SOURCE_SHAS "$scripts/landed-check.sh"

# ── release.sh ──────────────────────────────────────────────────────────────
# The release is the merge's side-effect, so every case runs against main
# after something landed. The fixture's main holds a fix since v0.2.0.
passes "$scripts/release.sh" # on topic: releases are cut from main
git checkout -q main
passes env DAFT_MERGE_RESULT=conflict "$scripts/release.sh" # post-merge fires on conflict too
printf 'stray\n' >stray.txt
fails "$scripts/release.sh" # nothing gets built on a dirty tree
rm stray.txt

passes "$scripts/release.sh" --dry-run
cp "$out" "$tmp/dry-run.log" # `passes` truncates $out before its own command reads it
passes grep -q '0.2.0 → 0.2.1' "$tmp/dry-run.log"
passes test "$(git log -1 --format=%s)" = 'fix(panel): something users would notice'

passes "$scripts/release.sh"
passes test "$(git log -1 --format=%s)" = 'release: v0.2.1'
passes test "$(git cat-file -t v0.2.1)" = tag
passes test -n "$(git tag --points-at HEAD --list v0.2.1)"
landed=$(git rev-parse HEAD)

# Idempotent: a second run releases nothing and writes no commit.
passes "$scripts/release.sh"
passes test "$(git rev-parse HEAD)" = "$landed"

# A tip that is ALREADY a release commit only gets its missing tag — which is
# how a branch cut under the old ritual still lands correctly.
git tag -d v0.2.1 >/dev/null
passes "$scripts/release.sh"
passes test "$(git cat-file -t v0.2.1)" = tag
passes test "$(git rev-parse HEAD)" = "$landed"

# The notes fragment is the annotation, and the release commit spends it.
mkdir -p .release-notes
# Written UNDER the template comment, as a real fragment is: the comment is
# scaffolding and must not reach the annotation (it once became its subject).
printf '<!-- What shipped, in prose.\n     Second comment line. -->\n\nA short title\n\nProse the fragment carried.\n' >.release-notes/next.md
git add -A
git commit -qm 'feat(panel): something worth a minor'
passes "$scripts/release.sh"
passes test "$(git log -1 --format=%s)" = 'release: v0.3.0'
passes sh -c "git tag -l --format='%(contents)' v0.3.0 | grep -q 'Prose the fragment carried'"
passes test "$(git tag -l --format='%(contents:subject)' v0.3.0)" = 'A short title'
passes sh -c "! git tag -l --format='%(contents)' v0.3.0 | grep -q -e '<!--' -e 'comment line'"
passes sh -c "! grep -q 'Prose the fragment carried' .release-notes/next.md"

# ── digest-baseline.sh ──────────────────────────────────────────────────────
passes "$scripts/digest-baseline.sh" main
exported=$(cat "$out")
passes test -s "$exported/live-state-v1.json"
rm -rf "$exported"
fails "$scripts/digest-baseline.sh" no-such-ref

cd "$root"
echo "test-hooks: $checks checks passed"
