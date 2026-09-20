#!/bin/zsh
# Re-makes the README's media (docs/media/) against a SYNTHETIC digest —
# never anybody's real usage. scripts/demo-digest.py writes one, and:
#
#   - the terminal GIFs are recorded from the tapes beside them, with a
#     throwaway PATH whose `usage-tui` / `usage-cli` wrappers read that
#     digest (`--digest`), so a tape types the commands a user would;
#   - the menu bar pictures come from the app itself: `--demo-digest` makes
#     every face render the file and nothing of this Mac, and `--snapshot`
#     draws the strip and the whole panel off-screen and quits. No screen is
#     captured, and the app that is already running is left alone.
#
#   scripts/media.sh [tape…|app]     default: the app and every docs/media/*.tape
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

targets=("$@")
(( ${#targets} )) || targets=(app "$MEDIA"/*.tape)

# The strip sits over the panel's right edge, as the status item does; the
# panel's corners are rounded here because the popover that rounds them on
# screen is not what drew it.
compose_app() {
  local snaps="$WORK/snapshots" radius=28 pad=40 gap=16
  scripts/bundle.sh >/dev/null
  "$ROOT/AgentUsage.app/Contents/MacOS/AgentUsage" \
    --demo-digest "$WORK/live-state.json" --snapshot "${snaps}" >/dev/null 2>&1
  for theme in dark light; do
    [[ -f "${snaps}/panel-${theme}.png" ]] || { echo "media: the app drew no panel-${theme}.png" >&2; exit 1; }
    ffmpeg -y -loglevel error -i "${snaps}/menubar-preview@2x.png" -i "${snaps}/panel-${theme}.png" \
      -filter_complex "
        [1]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(gt(abs(W/2-X),W/2-${radius})*gt(abs(H/2-Y),H/2-${radius}),if(lte(hypot(${radius}-(W/2-abs(W/2-X)),${radius}-(H/2-abs(H/2-Y))),${radius}),255,0),255)'[panel];
        [0]format=rgba[strip];
        [panel]pad=iw+2*${pad}:ih+2*${pad}+68+${gap}:${pad}:${pad}+68+${gap}:color=black@0[canvas];
        [canvas][strip]overlay=W-w-${pad}:${pad}" \
      -frames:v 1 "$MEDIA/menubar-${theme}.png"
    echo "Drawn:    docs/media/menubar-${theme}.png"
  done
}

for tape in "${targets[@]}"; do
  if [[ "$tape" == app ]]; then
    compose_app
    continue
  fi
  tape="${tape:A}"   # before the cd below: a relative argument names a file HERE
  name="${tape:t:r}"
  rm -rf "$WORK/frames"
  # vhs resolves `Output frames/` against its working directory.
  (cd "$WORK" && PATH="$WORK/bin:$PATH" vhs "$tape" >/dev/null)
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
