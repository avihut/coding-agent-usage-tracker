#!/bin/zsh
# Assembles ClaudeUsage.app from the SPM-built binary and signs it with the
# stable identity. Always launch the bundled app: a bare `swift run` binary
# has no Info.plist, so LSUIElement wouldn't apply and a Dock icon appears.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product ClaudeUsage --package-path "$ROOT"
swift build -c "$CONFIG" --product usaged --package-path "$ROOT"
swift build -c "$CONFIG" --product usage-cli --package-path "$ROOT"

APP="$ROOT/ClaudeUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/$CONFIG/ClaudeUsage" "$APP/Contents/MacOS/ClaudeUsage"
# The launchd engine rides inside the bundle so there is exactly one
# installed copy; sign it before the outer bundle seals over it. It reads
# the Keychain, so the stable identity matters (same ACL as the app).
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
