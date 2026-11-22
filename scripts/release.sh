#!/usr/bin/env bash
# The release as a SIDE-EFFECT of a merge (daft.yml post-merge), not as its
# intent: a merge brings in code, and issuing the release is what follows.
# Before this, the release was prepared BY HAND ON THE BRANCH — bump, commit,
# tag — which coupled the release to the merge's input: a squash or a merge
# commit then carried the version move, so its subject had to be
# 'release: vX.Y.Z' (commit-msg.sh), and the branch's tag was left behind on a
# commit that never landed. Nothing on a branch names a version now.
#
#   scripts/release.sh [--dry-run]
#
# The notes are assembled by release-notes.sh: the maintainer's
# .release-notes/next.md (the tag's title, prose written by hand) with the
# "## Release note" of every PR merged since the last tag merged in. PRs
# never edit next.md — every one that did conflicted with every other open
# PR. --dry-run prints them and writes nothing, so it runs anywhere: off
# main, and on a tree whose next.md is still being edited.
#
# NEVER pushes. Push and publish stay a human step, and release-check
# (pre-push) is the backstop if this ever leaves a release half made.
set -euo pipefail

# git exports these to every hook and they outrank -C; the cwd (the target
# worktree daft runs post-merge from) is authoritative. See digest-baseline.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

dry_run=false
[ "${1:-}" = "--dry-run" ] && dry_run=true

scripts=$(cd "$(dirname "$0")" && pwd)
identity=Sources/UsageCore/AppIdentity.swift
notes=.release-notes/next.md
# Line for line what next.md's own header says.
template='<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes.
     THE MAINTAINER'"'"'S FILE: pull requests never edit it. A change describes
     itself under "## Release note" in its PR description, and
     scripts/release.sh adds every merged PR'"'"'s entries under the headings
     here (Fixes, Features) when it cuts the release (docs/WORKFLOW.md).
     The FIRST LINE is the tag'"'"'s subject: make it a short title, then a
     blank line. This comment is stripped. -->'

say() { printf 'release: %s\n' "$1"; }
refuse() {
    printf 'release: %s\n' "$1" >&2
    shift
    [ $# -eq 0 ] || printf '%s\n' "$@" >&2
    exit 1
}

# post-merge fires on conflict too, and on an abandoned squash commit.
result=${DAFT_MERGE_RESULT:-}
if [ -n "$result" ] && [ "$result" != "success" ]; then
    say "merge result '$result' — nothing to release"
    exit 0
fi

branch=$(git symbolic-ref --short -q HEAD || true)
if [ "$branch" != "main" ]; then
    if ! $dry_run; then
        say "'$branch' is not main — releases are cut from main"
        exit 0
    fi
    say "previewing on '$branch' — a release is only ever cut from main"
fi
if [ -n "$(git status --porcelain)" ]; then
    if ! $dry_run; then
        refuse "the worktree is not clean — refusing to build a release commit on top" \
            "  commit or discard the changes, then: mise run release"
    fi
    say "the worktree is not clean — previewing it as it stands (a real run refuses)"
fi

current=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$identity")
[ -n "$current" ] || refuse "no version found in $identity"

# The annotation IS the release notes. Prose beats a list of subjects.
# Only the already-a-release-commit path below reads next.md alone; a new
# release assembles it with the PRs' notes (release-notes.sh assemble).
written_notes() { # → the fragment on stdout, or 1 when it says nothing
    [ -f "$notes" ] || return 1
    # The template's HTML comment is scaffolding, not notes. It used to ride
    # along: v0.102.0's annotation was cut with the comment as its SUBJECT and
    # had to be re-annotated by hand before the tag was pushed. Whole comment
    # lines go, then the blank lines they leave at the top.
    stripped=$(awk '
        /<!--/ { comment = 1 }
        !comment { print }
        /-->/ { comment = 0 }
    ' "$notes" | sed -e '/./,$!d')
    [ -n "$stripped" ] || return 1
    printf '%s\n' "$stripped"
}

tag_head() { # <version> <notes file>
    if $dry_run; then
        say "would tag v$1 on $(git rev-parse --short HEAD)"
        return 0
    fi
    # whitespace, not git's default strip: strip deletes every line that
    # starts with "#", and a markdown heading in next.md is one.
    git tag -a --cleanup=whitespace "v$1" -F "$2"
    say "tagged v$1"
}

message=$(mktemp)
trap 'rm -f "$message"' EXIT

# ── A release commit already landed ─────────────────────────────────────────
# A branch cut under the old ritual, or a squash named for the release it
# carries. Don't release twice — just make sure it has its tag, since
# release-check refuses to push a release commit without one.
if [ "$(git log -1 --format=%s)" = "release: v$current" ]; then
    if [ -n "$(git tag --points-at HEAD --list "v$current")" ]; then
        say "v$current is already tagged on this commit"
        exit 0
    fi
    if written_notes >"$message"; then
        say "annotating v$current from $notes"
    else
        git log -1 --format=%b >"$message"
        say "annotating v$current from the release commit's own body"
    fi
    [ -s "$message" ] || refuse "v$current has no notes to annotate with" \
        "  write $notes, then: mise run release"
    tag_head "$current" "$message"
    exit 0
fi

# ── Decide whether this merge released anything ─────────────────────────────
last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
range=${last:+$last..}HEAD
# The TYPE comes from subjects alone (on main each is a PR title or the
# commit itself). Bodies are whole PR descriptions now, and a release-note
# line such as "fix: the panel…" would otherwise read as a fix to release.
# Only the BREAKING CHANGE footer is a body's to declare.
subjects=$(git log --format='%s' "$range")
log=$(git log --format='%s%n%b' "$range")

# Here-strings, never `printf | grep -q`: grep -q exits at its first match,
# and under pipefail the printf it hung up on (SIGPIPE, once the log
# outgrows the pipe's buffer — squash bodies are whole PR descriptions)
# fails the test. Since v0.103.0 the log was 114 KB, and a range full of
# feat and fix read as "nothing releasable".
level="none"
if grep -qE '^(feat|fix)(\([^)]*\))?!: ' <<<"$subjects" ||
    grep -q '^BREAKING CHANGE' <<<"$log"; then
    level="major"
elif grep -qE '^feat(\([^)]*\))?: ' <<<"$subjects"; then
    level="minor"
elif grep -qE '^fix(\([^)]*\))?: ' <<<"$subjects"; then
    level="patch"
fi

if [ "$level" = none ]; then
    say "nothing releasable since ${last:-the first commit}"
    exit 0
fi

major=${current%%.*}
rest=${current#*.}
minor=${rest%%.*}
patch=${rest##*.}
# Pre-1.0 a breaking change is a minor bump, never an automatic jump to
# 1.0.0 — calling something 1.0 is a product decision.
if [ "$level" = major ] && [ "$major" = 0 ]; then
    say "a breaking change while the major is 0 — taking a minor bump, not 1.0.0"
    level="minor"
fi
case $level in
major) next="$((major + 1)).0.0" ;;
minor) next="$major.$((minor + 1)).0" ;;
patch) next="$major.$minor.$((patch + 1))" ;;
esac

say "$level bump since ${last:-the first commit}: $current → $next"

# next.md + every merged PR's "## Release note". A description that can't be
# read, or whose note is malformed, refuses the release: the fix is the PR
# description, and post-merge only warns, so the merge itself stands.
assembled=true
"$scripts/release-notes.sh" assemble "$range" "v$next" >"$message" || assembled=false
if [ -s "$message" ]; then
    say "notes from $notes and the merged PRs' descriptions"
else
    git log --format='- %s' "$range" >"$message"
    say "nothing in $notes and no PR release notes — annotating with the subjects since ${last:-the first commit}"
fi

if $dry_run; then
    say "would commit 'release: v$next' and tag it with these notes:"
    printf -- '------------------------------------------------------------------------\n'
    cat "$message"
    printf -- '------------------------------------------------------------------------\n'
    $assembled || refuse "a real run would refuse: fix what is marked ✗ above"
    exit 0
fi
$assembled || refuse "not released: fix what is marked ✗ above, then: mise run release"

# One commit: the version, and the fragment spent on it.
sed -i '' "s/static let version = \".*\"/static let version = \"$next\"/" "$identity"
staged=("$identity")
git add "$identity"
if [ -f "$notes" ]; then
    printf '%s\n' "$template" >"$notes"
    git add "$notes"
    staged+=("$notes")
fi
if ! {
    printf 'release: v%s\n\n' "$next"
    cat "$message"
} | git commit -q --cleanup=whitespace -F -; then
    # A commit that didn't happen (a locked signing agent, a hook) leaves
    # nothing half made: the tree was clean, so put back the two files this
    # staged, and the next run starts over instead of refusing a dirty tree.
    git restore --source=HEAD --staged --worktree -- "${staged[@]}"
    refuse "the release commit failed — nothing was released; fix the cause, then: mise run release"
fi
tag_head "$next" "$message"
say "not pushed — review it, then: git push origin main v$next && mise run publish"
