#!/bin/zsh
# Builds a transferable copy of the app for another Mac: universal (so it runs
# on Intel too), signed with a timestamp, zipped, and verified to survive the
# round trip. Deliberately writes to dist/ rather than re-signing the
# ClaudeUsage.app the dev loop launches.
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
APP="$DIST/ClaudeUsage.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Support/Info.plist")
ZIP="$DIST/ClaudeUsage-$VERSION.zip"

swift build -c release --product ClaudeUsage --arch arm64 --arch x86_64 --package-path "$ROOT"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/apple/Products/Release/ClaudeUsage" "$APP/Contents/MacOS/ClaudeUsage"
"$ROOT/scripts/icon.sh"
cp "$ROOT/.build/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
CODESIGN_TIMESTAMP=1 "$ROOT/scripts/sign.sh" "$APP"

# ditto, not zip: it round-trips bundle metadata and the signature intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Prove the archive still holds a valid signature before handing it over —
# a broken one is invisible until it fails on the other machine.
VERIFY=$(mktemp -d)
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "$ZIP" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/ClaudeUsage.app"
file "$VERIFY/ClaudeUsage.app/Contents/MacOS/ClaudeUsage" | sed 's/^[^:]*: //'

echo "Wrote: $ZIP"
shasum -a 256 "$ZIP"
