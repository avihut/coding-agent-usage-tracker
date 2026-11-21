#!/bin/zsh
# Assembles AgentUsage.app from the SPM-built binary and signs it with the
# machine-local identity sign.sh resolves (see that script). Always launch
# the bundled app: a bare `swift run` binary has no Info.plist, so LSUIElement
# wouldn't apply and a Dock icon appears.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product AgentUsage --package-path "$ROOT"
swift build -c "$CONFIG" --product usaged --package-path "$ROOT"
swift build -c "$CONFIG" --product usage-cli --package-path "$ROOT"

APP="$ROOT/AgentUsage.app"
# Assemble and sign in a STAGING bundle, then swap it into place by rename.
# The installed path is live: Claude Code status lines run its usage-cli every
# few seconds, and the daemon runs its usaged. Building in place left a fresh,
# still-unsigned binary at that path while codesign got to it, and a status
# line that ran it in that window made codesign fail ("Write permissions
# error", user-reported 2026-11-22). Built aside, the path only ever holds a
# whole, signed bundle; running processes keep the inodes they started from.
STAGE_ROOT="$ROOT/.build/bundle-staging"
STAGE="$STAGE_ROOT/AgentUsage.app"
# A staging or replaced bundle carries this bundle id too, so nothing may
# outlive the script: Spotlight would offer it to `ensure` (the 2026-10-04
# repoint incident started from a stray bundle).
trap 'rm -rf "$STAGE_ROOT"' EXIT
rm -rf "$STAGE_ROOT"
# What this script built through 0.101.0. A stale copy is still a launchable
# app under the OLD bundle id — a login item or Spotlight would start it, and
# it would host the engine against the old directories.
rm -rf "$ROOT/ClaudeUsage.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$STAGE/Contents/Info.plist"
# AppIdentity.swift is the ONE version source (the release-bump sed path);
# stamp the plist from it at bundle time. A hand-maintained plist version
# drifted two releases behind before the updater made it load-bearing —
# the self-updater verifies a downloaded bundle by this very key.
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/UsageCore/AppIdentity.swift")
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    "$STAGE/Contents/Info.plist"
cp "$ROOT/.build/$CONFIG/AgentUsage" "$STAGE/Contents/MacOS/AgentUsage"
# The launchd engine rides inside the bundle so there is exactly one
# installed copy; sign it before the outer bundle seals over it, with the
# same identity as the app so launchd sees one consistent job.
cp "$ROOT/.build/$CONFIG/usaged" "$STAGE/Contents/MacOS/usaged"
"$ROOT/scripts/sign.sh" "$STAGE/Contents/MacOS/usaged"
# The query CLI ships beside the daemon for the same one-copy reason —
# scripts and the Claude Code status line need a path that stays stable
# and CURRENT across releases. A dev-tree binary rots: a pre-v0.81.0
# .build/release leftover routed `session … tokens` into the credentialed
# bare fetch and hung a probe for two minutes.
cp "$ROOT/.build/$CONFIG/usage-cli" "$STAGE/Contents/MacOS/usage-cli"
"$ROOT/scripts/sign.sh" "$STAGE/Contents/MacOS/usage-cli"
"$ROOT/scripts/icon.sh"
cp "$ROOT/.build/icon/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
"$ROOT/scripts/sign.sh" "$STAGE"
# The swap: two renames on one volume. Between them the path is briefly
# absent, which a status line already treats as "no usage-cli"; it never
# holds a half-built or unsigned binary.
OLD="$STAGE_ROOT/replaced.app"
if [[ -e "$APP" ]]; then mv "$APP" "$OLD"; fi
mv "$STAGE" "$APP"
rm -rf "$OLD"
echo "Bundled: $APP"
