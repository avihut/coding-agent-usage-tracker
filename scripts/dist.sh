#!/bin/zsh
# Builds a transferable copy of the app for another Mac: universal (so it runs
# on Intel too), signed with a timestamp, zipped, and verified to survive the
# round trip. Deliberately writes to dist/ rather than re-signing the
# ClaudeUsage.app the dev loop launches. This zip is what `publish.sh` hands
# to GitHub Releases — the artifact the in-app updater downloads.
# A real signing identity is REQUIRED here (CODESIGN_REQUIRE_IDENTITY): an
# ad-hoc build is fine on the machine that built it, never as a release.
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="$ROOT/dist"
APP="$DIST/ClaudeUsage.app"
# AppIdentity.swift is the ONE version source — the plist is stamped from it,
# never trusted (it drifted two releases behind when it was hand-maintained,
# and the updater verifies downloaded bundles by this key).
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
    "$ROOT/Sources/UsageCore/AppIdentity.swift")
ZIP="$DIST/ClaudeUsage-$VERSION.zip"

# Fail on a missing identity now, not after three universal builds.
CODESIGN_REQUIRE_IDENTITY=1 "$ROOT/scripts/sign.sh" --which

swift build -c release --product ClaudeUsage --arch arm64 --arch x86_64 --package-path "$ROOT"
swift build -c release --product usaged --arch arm64 --arch x86_64 --package-path "$ROOT"
swift build -c release --product usage-cli --arch arm64 --arch x86_64 --package-path "$ROOT"

rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    "$APP/Contents/Info.plist"
cp "$ROOT/.build/apple/Products/Release/ClaudeUsage" "$APP/Contents/MacOS/ClaudeUsage"
# The daemon and the query CLI ride inside the bundle — same layout as
# bundle.sh, same one-installed-copy reasoning — and each inner binary is
# signed before the outer bundle seals over it.
cp "$ROOT/.build/apple/Products/Release/usaged" "$APP/Contents/MacOS/usaged"
CODESIGN_TIMESTAMP=1 CODESIGN_REQUIRE_IDENTITY=1 "$ROOT/scripts/sign.sh" "$APP/Contents/MacOS/usaged"
cp "$ROOT/.build/apple/Products/Release/usage-cli" "$APP/Contents/MacOS/usage-cli"
CODESIGN_TIMESTAMP=1 CODESIGN_REQUIRE_IDENTITY=1 "$ROOT/scripts/sign.sh" "$APP/Contents/MacOS/usage-cli"
"$ROOT/scripts/icon.sh"
cp "$ROOT/.build/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
CODESIGN_TIMESTAMP=1 CODESIGN_REQUIRE_IDENTITY=1 "$ROOT/scripts/sign.sh" "$APP"

# ditto, not zip: it round-trips bundle metadata and the signature intact.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# Prove the archive still holds a valid signature before handing it over —
# a broken one is invisible until it fails on the other machine.
VERIFY=$(mktemp -d)
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "$ZIP" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/ClaudeUsage.app"
BUNDLED=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
    "$VERIFY/ClaudeUsage.app/Contents/Info.plist")
if [[ "$BUNDLED" != "$VERSION" ]]; then
    echo "Version mismatch: bundle says $BUNDLED, AppIdentity says $VERSION" >&2
    exit 1
fi
file "$VERIFY/ClaudeUsage.app/Contents/MacOS/ClaudeUsage" | sed 's/^[^:]*: //'

echo "Wrote: $ZIP"
shasum -a 256 "$ZIP"
