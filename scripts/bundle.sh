#!/bin/zsh
# Assembles ClaudeUsage.app from the SPM-built binary and signs it with the
# stable identity. Always launch the bundled app: a bare `swift run` binary
# has no Info.plist, so LSUIElement wouldn't apply and a Dock icon appears.
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="${1:-release}"

swift build -c "$CONFIG" --product ClaudeUsage --package-path "$ROOT"

APP="$ROOT/ClaudeUsage.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/$CONFIG/ClaudeUsage" "$APP/Contents/MacOS/ClaudeUsage"
"$ROOT/scripts/icon.sh"
cp "$ROOT/.build/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
"$ROOT/scripts/sign.sh" "$APP"
echo "Bundled: $APP"
