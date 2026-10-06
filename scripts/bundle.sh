#!/bin/zsh
# Assembles AgentUsage.app from the SPM-built binary and signs it with the
# machine-local identity sign.sh resolves (see that script). Always launch
# the bundled app: a bare `swift run` binary has no Info.plist, so LSUIElement
# wouldn't apply and a Dock icon appears.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"

# SwiftPM's default build system links through clang with `--sysroot`, and
# clang reads the SDK's VERSION only from `-isysroot` — so the binary used to
# record its deployment target as its SDK (`sdk 15.0`), and macOS drew the
# app as one linked against a pre-26 SDK: the legacy look, no Liquid Glass,
# whatever SDK actually built it. Hand the linker the SDK the way it reads it.
SDK_LINK=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --show-sdk-path)")
swift build -c "$CONFIG" --product AgentUsage --package-path "$ROOT" "${SDK_LINK[@]}"
swift build -c "$CONFIG" --product usaged --package-path "$ROOT" "${SDK_LINK[@]}"
swift build -c "$CONFIG" --product usage-cli --package-path "$ROOT" "${SDK_LINK[@]}"
# And prove it: an app that records an older SDK than the one that built it
# is drawn in the old look, silently.
LINKED=$(vtool -show-build "$ROOT/.build/$CONFIG/AgentUsage" | awk '/sdk/ {print $2; exit}')
WANTED=$(xcrun --show-sdk-version)
if [[ "${LINKED%%.*}" != "${WANTED%%.*}" ]]; then
    echo "bundle: AgentUsage records SDK $LINKED, built with $WANTED — the app would draw in the old look" >&2
    exit 1
fi

APP="$ROOT/AgentUsage.app"
rm -rf "$APP"
# What this script built through 0.101.0. A stale copy is still a launchable
# app under the OLD bundle id — a login item or Spotlight would start it, and
# it would host the engine against the old directories.
rm -rf "$ROOT/ClaudeUsage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
# AppIdentity.swift is the ONE version source (the release-bump sed path);
# stamp the plist from it at bundle time. A hand-maintained plist version
# drifted two releases behind before the updater made it load-bearing —
# the self-updater verifies a downloaded bundle by this very key.
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/UsageCore/AppIdentity.swift")
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    "$APP/Contents/Info.plist"
cp "$ROOT/.build/$CONFIG/AgentUsage" "$APP/Contents/MacOS/AgentUsage"
# The launchd engine rides inside the bundle so there is exactly one
# installed copy; sign it before the outer bundle seals over it, with the
# same identity as the app so launchd sees one consistent job.
cp "$ROOT/.build/$CONFIG/usaged" "$APP/Contents/MacOS/usaged"
"$ROOT/scripts/sign.sh" "$APP/Contents/MacOS/usaged"
# The query CLI ships beside the daemon for the same one-copy reason —
# scripts and the Claude Code status line need a path that stays stable
# and CURRENT across releases. A dev-tree binary rots: a pre-v0.81.0
# .build/release leftover routed `session … tokens` into the credentialed
# bare fetch and hung a probe for two minutes.
cp "$ROOT/.build/$CONFIG/usage-cli" "$APP/Contents/MacOS/usage-cli"
"$ROOT/scripts/sign.sh" "$APP/Contents/MacOS/usage-cli"
"$ROOT/scripts/icon.sh"
cp "$ROOT/.build/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
"$ROOT/scripts/sign.sh" "$APP"
echo "Bundled: $APP"
