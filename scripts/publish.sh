#!/bin/zsh
# Publishes the current version as a GitHub release: builds the dist zip and
# attaches it to a release for the version's tag — the artifact the in-app
# updater's feed announces. Run AFTER the release commit and its annotated
# tag exist and are pushed; the release notes are the tag's own annotation.
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/UsageCore/AppIdentity.swift")
TAG="v$VERSION"
ZIP="$ROOT/dist/ClaudeUsage-$VERSION.zip"

if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG does not exist — tag the release commit first." >&2
    exit 1
fi

"$ROOT/scripts/dist.sh"

NOTES=$(git -C "$ROOT" tag -l --format='%(contents)' "$TAG")
if gh release view "$TAG" --repo "$(git -C "$ROOT" remote get-url origin)" >/dev/null 2>&1; then
    # Re-publishing the same version replaces the asset, never the notes.
    gh release upload "$TAG" "$ZIP" --clobber
else
    gh release create "$TAG" --verify-tag --title "$TAG" --notes "$NOTES" "$ZIP"
fi

echo "Published $TAG"
