#!/bin/zsh
# Re-records the README's terminal GIFs (docs/media/*.gif) from the tapes
# beside them, against a SYNTHETIC digest — never anybody's real usage:
# scripts/demo-digest.py writes one, and a throwaway PATH puts `usage-tui`
# and `usage-cli` wrappers in front that read it (`--digest`), so the tapes
# type the commands a user would.
#
#   scripts/media.sh [tape…]     default: every docs/media/*.tape
#
# Needs vhs and ffmpeg (`brew install vhs ffmpeg`) — deliberately not pinned
# in mise.toml, since nothing but this script wants them. vhs only captures
# frames here: its own encode step fails silently against ffmpeg 8+ (vhs
# 0.12), so the GIF is assembled below.
set -euo pipefail

ROOT="${0:A:h:h}"
MEDIA="$ROOT/docs/media"
FPS=12          # of the 50 vhs captures; a dashboard needs no more
BACKGROUND="0x161618"

for tool in vhs ffmpeg python3; do
  command -v "$tool" >/dev/null || { echo "media: $tool not found (brew install vhs ffmpeg)" >&2; exit 1; }
done

cd "$ROOT"
swift build --product usage-cli
cargo build --release --manifest-path tui/Cargo.toml

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 scripts/demo-digest.py "$WORK/live-state.json"

mkdir "$WORK/bin"
for face in "usage-cli:$ROOT/.build/debug/usage-cli" "usage-tui:$ROOT/tui/target/release/usage-tui"; do
  cat > "$WORK/bin/${face%%:*}" <<EOF
#!/bin/sh
exec "${face#*:}" "\$@" --digest "$WORK/live-state.json"
EOF
  chmod +x "$WORK/bin/${face%%:*}"
done

tapes=("$@")
(( ${#tapes} )) || tapes=("$MEDIA"/*.tape)

for tape in "${tapes[@]}"; do
  name="${tape:t:r}"
  rm -rf "$WORK/frames"
  # vhs resolves `Output frames/` against its working directory.
  (cd "$WORK" && PATH="$WORK/bin:$PATH" vhs "${tape:A}" >/dev/null)
  [[ -f "$WORK/frames/frame-text-00001.png" ]] || { echo "media: vhs captured nothing for $name" >&2; exit 1; }
  # Text and cursor arrive as separate layers; pad, since vhs adds its
  # padding in the encode step this replaces.
  ffmpeg -y -loglevel error \
    -framerate 50 -i "$WORK/frames/frame-text-%05d.png" \
    -framerate 50 -i "$WORK/frames/frame-cursor-%05d.png" \
    -filter_complex "[0][1]overlay,fps=$FPS,pad=iw+48:ih+48:24:24:color=$BACKGROUND,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
    "$MEDIA/$name.gif"
  echo "Recorded: docs/media/$name.gif ($(du -h "$MEDIA/$name.gif" | cut -f1 | tr -d ' '))"
done
