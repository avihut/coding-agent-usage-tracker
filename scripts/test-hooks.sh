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

# No network, ever: release-notes.sh reads PR descriptions with gh, so a
# stub stands first on PATH for the whole file. It answers like GitHub for an
# issue's number (24) and fails like a dead network for anything else.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/bin/sh
for arg in "$@"; do
    if [ "$arg" = 24 ] || [ "$arg" = n=24 ]; then
        echo "GraphQL: Could not resolve to a PullRequest with the number of 24. (repository.pullRequest)" >&2
        exit 1
    fi
done
echo "error connecting to api.github.com (test-hooks' gh stub: no network here)" >&2
exit 1
STUB
chmod +x "$tmp/bin/gh"
PATH="$tmp/bin:$PATH"
unset RELEASE_NOTES_PRS RELEASE_NOTES_FILE

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

# ── release-notes.sh: the "## Release note" grammar ────────────────────────
notes_sh="$scripts/release-notes.sh"
entries_of() { # <text> [mode] → the entries printed, whatever the status
    printf '%s' "$1" | "$notes_sh" "${2:-entries}" 2>/dev/null || true
}
status_of() { # <text> → the `entries` exit status
    local status=0
    printf '%s' "$1" | "$notes_sh" entries >/dev/null 2>&1 || status=$?
    echo "$status"
}
T=$'\t'
body=$'## What and why\n\nx\n\n## Release note\n\nFixes: the daemon stays up.\n\n## How it was verified\n\nFixes: not this one.\n'
passes test "$(entries_of "$body")" = "fixes${T}the daemon stays up."
passes with_stdin "$body" "$notes_sh" check
# `none` is a note: nothing for the release, and a green check.
body=$'## Release note\n\n_None._\n'
passes test "$(status_of "$body")" = 0
passes test -z "$(entries_of "$body")"
passes with_stdin "$body" "$notes_sh" check
# No section (1); the template untouched — its hint is a comment (2);
# prose without a label (2). Each is a red check.
body=$'## What and why\n\nA change.\n'
passes test "$(status_of "$body")" = 1
fails with_stdin "$body" "$notes_sh" check
template=$(cat "$root/.github/PULL_REQUEST_TEMPLATE.md")
passes test "$(status_of "$template")" = 2
fails with_stdin "$template" "$notes_sh" check
body=$'## Release note\n\nThe daemon stays up now.\n'
passes test "$(status_of "$body")" = 2
fails with_stdin "$body" "$notes_sh" check
# A description edited on github.com arrives CRLF.
passes test "$(entries_of $'## Release note\r\n\r\nFixes: crlf.\r\n')" = "fixes${T}crlf."
# Two entries, a wrapped line, bold labels; a bare label's bullets; the
# signature after the note stays out, and so does a label after it.
body=$'### release notes:\n**Fixes:** one\nwrapped.\nNew: two\n\nFeatures:\n\n- b1\n- b2\n  more\n\nGenerated with a tool\n\nFixes: after the signature\n'
passes test "$(entries_of "$body")" = "fixes${T}one wrapped.
features${T}two
features${T}b1
features${T}b2 more"
# A heading inside a code fence is not one; "#45 …" is not a heading.
passes test "$(status_of $'## What\n\n```\n## Release note\nFixes: fake\n```\n')" = 1
passes test "$(entries_of $'## Release note\n\nFixes: a\n#45 is related\n')" = "fixes${T}a #45 is related"
# Commit messages: "Release note — <Label>: …", any dash or a colon; prose
# ABOUT a release note is not one. Hooks may run without a UTF-8 locale.
message=$'fix: x\n\nRelease note \xe2\x80\x94 Fixes: the em dash.\nwrapped\n\nRelease note -- New: the double hyphen.\n\nRelease note: a Fixes entry in next.md.\n\nCo-Authored-By: someone\n'
passes test "$(entries_of "$message" commit-entries)" = "fixes${T}the em dash. wrapped
features${T}the double hyphen."
passes test "$(printf '%s' "$message" | LC_ALL=C "$notes_sh" commit-entries | head -n 1)" = "fixes${T}the em dash. wrapped"
passes test "$(printf '%s' $'## Release note\n\nFixes: caf\xc3\xa9 \xe2\x80\x94 ok\n' | LC_ALL=C "$notes_sh" entries)" = "fixes${T}café — ok"
# Loose lists (blank lines between bullets) and numbered ones; `<!--` in a
# code span is text; a label in mid-paragraph must be written as one, so
# wrapped prose that starts "new:" stays prose; bold around the whole entry.
body=$'## Release note\n\nFeatures:\n\n- b1\n\n- b2\n\n1. n1\n2) n2\n\nsignature\n\n## Release note\n\n**Fixes: bold.**\n'
passes test "$(entries_of "$body")" = "features${T}b1
features${T}b2
features${T}n1
features${T}n2"
passes test "$(entries_of $'## Release note\n\n**Fixes: bold.**\n')" = "fixes${T}bold."
body=$'## Release note\n\nFixes: the `<!--` parser stays\nwhole; it explains what is\nnew: a dot.\n'
passes test "$(entries_of "$body")" = "fixes${T}the \`<!--\` parser stays whole; it explains what is new: a dot."
passes test "$(printf '%s' "$body" | LC_ALL=C "$notes_sh" entries)" = "fixes${T}the \`<!--\` parser stays whole; it explains what is new: a dot."
# Whitespace runs an outsider can write cost nothing (bash trims them a
# character at a time: 65 000 spaces took minutes).
passes test "$(entries_of $'## Release note\n\nFixes: x\n'"$(printf '%*s' 65000 '')"$'y\t\t\ty\n')" = "fixes${T}x y y"
fails "$notes_sh" no-such-mode

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
gate_halves() { # the fixture's mise.toml, with these halves of the gate
    printf '[tasks.tool]\nrun = "scripts/tool.sh"\n\n[tasks.gate]\ndepends = [%s]\n' "$1" >mise.toml
}
gate_halves '"gate-lint"'
mkdir -p .github/workflows
cat >.github/workflows/ci.yml <<'YAML'
jobs:
  lint:
    steps:
      - name: mise run gate-lint
        run: mise run --continue-on-error gate-lint
  ci-gate:
    needs:
      - lint
    if: always()
YAML
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
# ci-gate is the one required check: a job it does not need, or a half of
# the gate no job runs, is a check a pull request can fail and still merge.
trips .github/workflows/ci.yml $'  orphan:\n    runs-on: ubuntu-latest'
gate_halves '"gate-lint", "gate-docs"'
git add -A
fails "$scripts/guard.sh"
fails "$scripts/guard.sh" --staged
git reset -q --hard "$base"

# Every check the merge ruleset requires is a job a workflow defines, by the
# name GitHub reports: its `name:` when it has one, else its id.
mkdir -p .github/rulesets
printf 'jobs:\n  title-id:\n    name: title-check\n    steps:\n      - name: not-a-job\n' \
    >.github/workflows/pr.yml
requires() { # <context>… → the fixture's ruleset record
    local list="" context
    for context in "$@"; do list+="${list:+, }{ \"context\": \"$context\" }"; done
    printf '{"rules": [{"parameters": {"required_status_checks": [%s]}}]}\n' "$list" \
        >.github/rulesets/main-merge-requirements.json
    git add -A
}
requires ci-gate title-check
passes "$scripts/guard.sh"
passes "$scripts/guard.sh" --staged
for context in ghost title-id not-a-job; do
    requires ci-gate "$context"
    fails "$scripts/guard.sh"
    fails "$scripts/guard.sh" --staged
done
git reset -q --hard "$base"
git clean -qfd

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
# What it wrote back is the header next.md itself carries.
passes test "$(cat .release-notes/next.md)" = "$(sed -n '1,/-->/p' "$root/.release-notes/next.md")"

# ── release.sh + release-notes.sh assemble: notes from PR descriptions ──────
# The maintainer's title, prose and a legacy entry in next.md (committed on
# main: PRs never edit it), then what landed. A PR's note is its description
# AS IT STOOD AT THE MERGE: the live one (the fixture stands in for GitHub),
# unless edited after the merge — then the copy in its squash commit, whose
# body GitHub fills with the description when the merge message is fixed.
cat >>.release-notes/next.md <<'NOTES'
Title by hand

Prose by hand.

Fixes
- A legacy fix, written before notes moved to PR descriptions.
NOTES
git add -A
git commit -qm 'docs(release): the next release, titled'
squash() { # <subject> <body> — a commit, its body as given
    git commit -q --allow-empty -F - <<<"$1"$'\n\n'"$2"
}
prs="$tmp/prs.json"
: >"$tmp/prs.jsonl"
pr() { # <number> <description now> [lastEditedAt mergedAt] — GitHub's side
    jq -n --argjson n "$1" --arg b "$2" --arg e "${3:-}" --arg m "${4:-}" \
        '{number: $n, body: $b}
         + (if $e == "" then {} else {lastEditedAt: $e} end)
         + (if $m == "" then {} else {mergedAt: $m} end)' >>"$tmp/prs.jsonl"
    jq -s . "$tmp/prs.jsonl" >"$prs"
}
merged() { # <number> <subject> <description> — squashed by GitHub, unedited since
    squash "$2" "$3"
    pr "$1" "$3"
}
# Over the pipe's 64 KB: the bump test once read a SIGPIPE as "no feat".
filler=$(printf 'A long description line, as whole PR bodies are. %.0s' $(seq 1 2500))
merged 11 'fix(panel): margins hold (#11)' "## What and why

$filler

## Release note

Fixes: the panel keeps its margins with every agent's models in the Activity table; long model names shorten with an ellipsis instead of pushing the content wider.

Generated with a tool"
# shellcheck disable=SC2016 # literal on purpose: it must reach the tag unexpanded
hostile='New: a `feature` with 50% \ $(touch pwned) *globs* and "quotes"'
merged 12 'feat(cli): a hostile feature (#12)' "## Release note

$hostile"
merged 13 'chore(ci): bump a dependency (#13)' 'Bumps x from 1 to 2.'
merged 14 'fix(tui): a fix with no note (#14)' $'## What and why\n\nForgot the note.'
merged 15 'fix(core): nothing user-visible (#15)' $'## Release note\n\nnone'
# A hand-written merge message: the note is only in the description.
squash 'fix(app): merged with a hand-written message (#16)' 'A message, not the description.'
pr 16 $'## Release note\n\nFixes: read from the description.'
# Auto-merge fixed the squash message when it was armed; the description was
# reworded after that, before the merge: the description wins (#42's case).
squash 'fix(menu): reworded after auto-merge was armed (#18)' $'## Release note\n\nFixes: the wording as armed.'
pr 18 $'## Release note\n\nFixes: the wording as merged.' 2026-11-21T23:28:14Z 2026-11-21T23:50:58Z
# Edited AFTER the merge: nobody reviewed that, so the squash copy wins.
squash 'fix(sync): edited after its merge (#19)' $'## Release note\n\nFixes: as reviewed and merged.'
pr 19 $'## Release note\n\nFixes: an edit nobody reviewed.' 2026-11-22T09:00:00Z 2026-11-21T23:50:58Z
squash 'fix(daemon): a direct commit' $'Why.\n\nRelease note \xe2\x80\x94 Fixes: a direct fix, from its commit message.\n\nCo-Authored-By: someone'
squash 'fix(cli): closes an issue (#24)' $'Release note: Fixes: a fix whose subject ends in an issue.'

expected="$tmp/expected-notes.txt"
cat >"$expected" <<'NOTES'
Title by hand

Prose by hand.

Fixes
- A legacy fix, written before notes moved to PR descriptions.
- The panel keeps its margins with every agent's models in the Activity
  table; long model names shorten with an ellipsis instead of pushing the
  content wider.
- Read from the description.
- The wording as merged.
- As reviewed and merged.
- A direct fix, from its commit message.
- A fix whose subject ends in an issue.

Features
- A `feature` with 50% \ $(touch pwned) *globs* and "quotes"
NOTES
dry_notes() { sed -n '/^-----/,/^-----/p' "$1" | sed '1d;$d'; }

passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh" --dry-run
cp "$out" "$tmp/dry-run.log"
passes grep -q '0.3.0 → 0.4.0' "$tmp/dry-run.log" # a feat, past a 128 KB log
passes diff "$expected" <(dry_notes "$tmp/dry-run.log")
passes grep -q '#14 has no "## Release note"' "$tmp/dry-run.log" # a fix without one warns
passes sh -c "! grep -q -e '#13' -e '#15' -e '#16' -e '#11' '$tmp/dry-run.log'" # these don't
passes grep -q '#18: its squash commit holds an older note' "$tmp/dry-run.log"
passes grep -q "#19's description was edited AFTER its merge" "$tmp/dry-run.log"
passes grep -q 'ends in (#24), which is not a pull request' "$tmp/dry-run.log"
passes test ! -e pwned
# A preview while next.md is still being edited, uncommitted, and off main.
printf -- '- Being written.\n' >>.release-notes/next.md
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh" --dry-run
cp "$out" "$tmp/step.log"
passes grep -q -- '- Being written.' "$tmp/step.log"
fails env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh" # the real run refuses a dirty tree
git checkout -q -- .release-notes/next.md
git checkout -q -b preview
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh" --dry-run
cp "$out" "$tmp/step.log"
passes grep -q "previewing on 'preview'" "$tmp/step.log"
git checkout -q main
git branch -q -D preview
# GitHub out of reach (the stub's dead network): a squash copy stands in,
# flagged; a fix whose note is ONLY in its description refuses the release;
# a chore only warns. A malformed note refuses too. Nothing is written.
tip=$(git rev-parse HEAD)
fails "$scripts/release.sh" --dry-run
cp "$out" "$tmp/step.log"
passes grep -q '#11: its description could not be read .* using the copy in its squash commit' "$tmp/step.log"
passes grep -q '✗ #16 .*its description could not be read' "$tmp/step.log"
passes grep -q 'release: #13 .*could not be read — nothing from it' "$tmp/step.log"
fails "$scripts/release.sh"
jq '(.[] | select(.number == 16) | .body) = "## Release note\n\nJust prose, no label."' "$prs" >"$tmp/bad.json"
fails env RELEASE_NOTES_PRS="$tmp/bad.json" "$scripts/release.sh"
cp "$out" "$tmp/step.log"
passes grep -q '#16: the "## Release note" section has no label' "$tmp/step.log"
printf 'not json' >"$tmp/not.json"
fails env RELEASE_NOTES_PRS="$tmp/not.json" "$scripts/release.sh"
passes test "$(git rev-parse HEAD)" = "$tip"
passes test -z "$(git tag --list v0.4.0)"
# gh's own "not a pull request" (the stub's answer for 24) falls back too.
passes "$notes_sh" assemble HEAD~1..HEAD v0.0.0
cp "$out" "$tmp/step.log"
passes grep -q 'ends in (#24), which is not a pull request' "$tmp/step.log"

# The release: the annotation IS the assembled notes, and next.md is spent.
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh"
passes test "$(git log -1 --format=%s)" = 'release: v0.4.0'
# As publish.sh reads it ($(…) drops the trailing newlines).
passes test "$(git tag -l --format='%(contents:subject)%0a%0a%(contents:body)' v0.4.0)" = "$(cat "$expected")"
passes test "$(git log -1 --format=%b)" = "$(cat "$expected")"
passes test "$(cat .release-notes/next.md)" = "$(sed -n '1,/-->/p' "$root/.release-notes/next.md")"
# A release-note line is not a commit type: a chore whose note says "fix:"
# cuts nothing (the bump reads subjects).
merged 20 'chore(docs): a note in lower case (#20)' $'## Release note\n\nfix: lower case, and still no release.'
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh"
passes test "$(git log -1 --format=%s)" = 'chore(docs): a note in lower case (#20)'
# A PR that ALSO edited next.md: its entry may land twice, and says so.
printf -- '- Its entry, in next.md too.\n' >>.release-notes/next.md
git add -A
git commit -q -F - <<<$'fix(menubar): wrote next.md as well (#21)\n\n## Release note\n\nFixes: its entry.'
pr 21 $'## Release note\n\nFixes: its entry.'
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh" --dry-run
cp "$out" "$tmp/step.log"
passes grep -q '#21 also edited .release-notes/next.md' "$tmp/step.log"
git reset -q --hard HEAD~1
# Nothing in next.md, a PR note: titled with the version. Its body is shaped
# as squash merges on main carry one: wrapped, signature, trailer block.
merged 17 'fix(panel): one more (#17)' $'## What and why\n\nWhy.\n\n## Release note\n\nFixes: one more, its description wrapped as a squash commit\nwraps it.\n\nGenerated with a tool\n\n---------\n\nCo-authored-by: someone <someone@example.invalid>'
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh"
passes test "$(git tag -l --format='%(contents)' v0.4.1)" = $'v0.4.1\n\nFixes\n- Lower case, and still no release.\n- One more, its description wrapped as a squash commit wraps it.'
# A merged note is the text as merged (a later edit of the description is
# ignored), so rewording one is the maintainer's edit of the annotation,
# before pushing (docs/WORKFLOW.md): `git tag -f -a` opens it in the editor.
# The pre-push check still holds the tag whole.
printf 'v0.4.1\n\nFixes\n- One more, reworded.\n' >"$tmp/reworded.txt"
git tag -f -a v0.4.1 -F "$tmp/reworded.txt" >/dev/null
passes test "$(git tag -l --format='%(contents:body)' v0.4.1 | tail -n 2 | head -n 1)" = '- One more, reworded.'
passes with_stdin "refs/heads/main $(git rev-parse HEAD) refs/heads/main $(git rev-parse "v0.4.0^{commit}")
refs/tags/v0.4.1 $(git rev-parse v0.4.1) refs/tags/v0.4.1 $zero
" "$scripts/release-check.sh"

# next.md's own shape: markdown headings reach the tag (git tag's default
# cleanup deletes every "#" line), a heading that is no section ends the one
# above it, and a next.md that starts with a section has no title.
merged 31 'fix(panel): keeps a name (#31)' $'## Release note\n\nFixes: macOS keeps its case.'
printf 'Fixes\n- A fix by hand.\n' >>.release-notes/next.md
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh" --dry-run
passes test "$(dry_notes "$out")" = $'v0.4.2\n\nFixes\n- A fix by hand.\n- macOS keeps its case.'
git checkout -q -- .release-notes/next.md
printf '# A title with a hash\n\n## Fixes\n- A fix by hand.\n\n## Upgrading\n\nPull and rebuild.\n' >>.release-notes/next.md
git add -A
git commit -qm 'docs(release): a titled release, in markdown'
cat >"$expected" <<'NOTES'
# A title with a hash

## Fixes
- A fix by hand.
- macOS keeps its case.

## Upgrading

Pull and rebuild.
NOTES
# A commit that fails (here a hook; a locked signing agent alike) leaves the
# tree as it was, so the next run starts over rather than refusing it.
mkdir -p "$tmp/failing-hooks"
printf '#!/bin/sh\nexit 1\n' >"$tmp/failing-hooks/commit-msg"
chmod +x "$tmp/failing-hooks/commit-msg"
tip=$(git rev-parse HEAD)
fails env RELEASE_NOTES_PRS="$prs" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_VALUE_0="$tmp/failing-hooks" "$scripts/release.sh"
passes test "$(git rev-parse HEAD)" = "$tip"
passes test -z "$(git status --porcelain)"
passes env RELEASE_NOTES_PRS="$prs" "$scripts/release.sh"
passes test "$(git tag -l --format='%(contents:subject)%0a%0a%(contents:body)' v0.4.2)" = "$(cat "$expected")"
passes test "$(git log -1 --format=%b)" = "$(cat "$expected")"

# ── digest-baseline.sh ──────────────────────────────────────────────────────
passes "$scripts/digest-baseline.sh" main
exported=$(cat "$out")
passes test -s "$exported/live-state-v1.json"
rm -rf "$exported"
fails "$scripts/digest-baseline.sh" no-such-ref

cd "$root"
echo "test-hooks: $checks checks passed"
