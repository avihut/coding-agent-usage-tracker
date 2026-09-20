#!/bin/zsh
# Publishes the current version as a GitHub release: the tag's own annotation
# as the notes, and NO binary (2026-09-20). A macOS app strangers can open
# needs a Developer ID and notarization; without them a downloaded zip is one
# Gatekeeper rejects, so the project ships source and every install is built
# and signed by the Mac that runs it (README → Install). The release still
# matters: it is the feed every install's update check reads — a release is
# what makes "a new version is tagged, pull and rebuild" appear in the app.
#
# Run AFTER the release commit and its annotated tag exist and are pushed.
# `mise run dist` still builds a signed zip for carrying to another Mac of
# your own; nothing here uploads it, and nothing should.
set -euo pipefail

ROOT="${0:A:h:h}"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/UsageCore/AppIdentity.swift")
TAG="v$VERSION"

if ! git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG does not exist — tag the release commit first." >&2
    exit 1
fi

cd "$ROOT"
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Release $TAG already exists — nothing to publish."
    exit 0
fi

# subject + body, NOT %(contents): tags are GPG-signed, and %(contents) carries
# the signature block — every release through v0.100.1 ended in one.
NOTES=$(git tag -l --format='%(contents:subject)%0a%0a%(contents:body)' "$TAG")
gh release create "$TAG" --verify-tag --title "$TAG" --notes "$NOTES"

echo "Published $TAG (notes only — releases carry no binary)"
