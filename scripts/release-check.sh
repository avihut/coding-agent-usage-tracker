#!/usr/bin/env bash
# pre-push hook body: every release being pushed is a whole one. CLAUDE.md:
# "Every commit that bumps AppIdentity.version gets a matching annotated tag
# (vX.Y.Z) on that commit, pushed alongside it" — and publish.sh reads the
# tag's annotation as the GitHub release notes, so a lightweight tag ships
# a release with no notes.
#
# Reads git's pre-push lines on stdin:
#   <local ref> <local sha> <remote ref> <remote sha>
# Local only — never asks the remote anything.
set -euo pipefail

zero=0000000000000000000000000000000000000000
identity=Sources/UsageCore/AppIdentity.swift
failures=0
pushed_tags=()
release_commits=()

fail() {
    failures=$((failures + 1))
    printf '✗ %s\n' "$1" >&2
    shift
    [ $# -eq 0 ] || printf '%s\n' "$@" >&2
}

version_at() {
    git show "$1:$identity" 2>/dev/null |
        sed -n 's/.*static let version = "\(.*\)".*/\1/p'
}

while read -r local_ref local_sha _remote_ref remote_sha; do
    [ "$local_sha" = "$zero" ] && continue # a delete pushes nothing to check

    case "$local_ref" in
    refs/tags/v*)
        tag=${local_ref#refs/tags/}
        pushed_tags+=("$tag")
        if [ "$(git cat-file -t "$local_ref")" != "tag" ]; then
            fail "$tag is a lightweight tag — the annotation IS the release notes" \
                "  git tag -d $tag && git tag -a $tag <commit>"
            continue
        fi
        commit=$(git rev-parse "$local_ref^{commit}")
        if [ "v$(version_at "$commit")" != "$tag" ]; then
            fail "$tag sits on $(git rev-parse --short "$commit"), where AppIdentity.version is $(version_at "$commit")"
        fi
        ;;
    refs/heads/*)
        if [ "$remote_sha" = "$zero" ]; then
            range=("$local_sha" --not --remotes)
        else
            range=("$remote_sha..$local_sha")
        fi
        while IFS= read -r commit; do
            [ -n "$commit" ] && release_commits+=("$commit")
        done < <(git rev-list --grep='^release: v' "${range[@]}")
        ;;
    esac
done

for commit in ${release_commits[@]+"${release_commits[@]}"}; do
    short=$(git rev-parse --short "$commit")
    subject=$(git log -1 --format=%s "$commit")
    tag=${subject#release: }
    if [ "v$(version_at "$commit")" != "$tag" ]; then
        fail "$short '$subject' but AppIdentity.version there is $(version_at "$commit")"
        continue
    fi
    if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        fail "$short '$subject' has no tag — git tag -a $tag $short"
        continue
    fi
    if [ "$(git cat-file -t "refs/tags/$tag")" != "tag" ]; then
        fail "$tag is a lightweight tag — the annotation IS the release notes"
    fi
    if [ "$(git rev-parse "refs/tags/$tag^{commit}")" != "$commit" ]; then
        fail "$tag points at $(git rev-parse --short "refs/tags/$tag^{commit}"), not at the release commit $short"
    fi
    # Whether the remote already has the tag is unknowable without asking
    # it, so an absent tag in THIS push is a nudge, never a refusal.
    case " ${pushed_tags[*]-} " in
    *" $tag "*) ;;
    *) echo "note: $tag is not part of this push — if the remote lacks it: git push origin $tag" >&2 ;;
    esac
done

if [ "$failures" -gt 0 ]; then
    exit 1
fi
echo "release-check: ${#release_commits[@]} release commit(s), ${#pushed_tags[@]} tag(s) — consistent"
