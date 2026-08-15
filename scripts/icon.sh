#!/bin/zsh
# Ensures .build/icon/AppIcon.icns is up to date, rendering it from
# scripts/icon.swift only when the renderer changed. No icon asset is checked
# in — the Swift renderer is the single source of truth for the mark.
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/.build/icon"
ICNS="$OUT/AppIcon.icns"

if [[ -f "$ICNS" && ! "$ROOT/scripts/icon.swift" -nt "$ICNS" ]]; then
  exit 0
fi

rm -rf "$OUT/AppIcon.iconset"
mkdir -p "$OUT"
swift "$ROOT/scripts/icon.swift" "$OUT/AppIcon.iconset"
iconutil -c icns "$OUT/AppIcon.iconset" -o "$ICNS"
echo "Rendered: $ICNS"
