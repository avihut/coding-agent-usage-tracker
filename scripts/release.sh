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
# NEVER pushes. Push and publish stay a human step, and release-check
# (pre-push) is the backstop if this ever leaves a release half made.
set -euo pipefail

# git exports these to every hook and they outrank -C; the cwd (the target
# worktree daft runs post-merge from) is authoritative. See digest-baseline.sh.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

dry_run=false
[ "${1:-}" = "--dry-run" ] && dry_run=true

identity=Sources/UsageCore/AppIdentity.swift
notes=.release-notes/next.md
template='<!-- What shipped, in prose. This becomes the annotation of the next
     release tag, which publish.sh ships as the GitHub release notes. -->'

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
    say "'$branch' is not main — releases are cut from main"
    exit 0
fi
if [ -n "$(git status --porcelain)" ]; then
    refuse "the worktree is not clean — refusing to build a release commit on top" \
        "  commit or discard the changes, then: mise run release"
fi

current=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$identity")
[ -n "$current" ] || refuse "no version found in $identity"

# The annotation IS the release notes. A fragment written on the branch beats
# a list of subjects, and it rode the pre-merge gate like any other file.
written_notes() { # → the fragment on stdout, or 1 when it says nothing
    [ -f "$notes" ] || return 1
    grep -vE '^[[:space:]]*(<!--|-->|$)' "$notes" | grep -q . || return 1
    cat "$notes"
}

tag_head() { # <version> <notes file>
    if $dry_run; then
        say "would tag v$1 on $(git rev-parse --short HEAD)"
        return 0
    fi
    git tag -a "v$1" -F "$2"
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
log=$(git log --format='%s%n%b' "$range")

level="none"
if printf '%s\n' "$log" | grep -qE '^(feat|fix)(\([^)]*\))?!: ' ||
    printf '%s\n' "$log" | grep -q '^BREAKING CHANGE'; then
    level="major"
elif printf '%s\n' "$log" | grep -qE '^feat(\([^)]*\))?: '; then
    level="minor"
elif printf '%s\n' "$log" | grep -qE '^fix(\([^)]*\))?: '; then
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
if $dry_run; then
    say "would commit 'release: v$next' and tag it"
    exit 0
fi

if written_notes >"$message"; then
    say "notes from $notes"
else
    git log --format='- %s' "$range" >"$message"
    say "no $notes — annotating with the subjects since ${last:-the first commit}"
fi

# One commit: the version, and the fragment spent on it.
sed -i '' "s/static let version = \".*\"/static let version = \"$next\"/" "$identity"
git add "$identity"
if [ -f "$notes" ]; then
    printf '%s\n' "$template" >"$notes"
    git add "$notes"
fi
{
    printf 'release: v%s\n\n' "$next"
    cat "$message"
} | git commit -q -F -
tag_head "$next" "$message"
say "not pushed — review it, then: git push origin main v$next && mise run publish"
