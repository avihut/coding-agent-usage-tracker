# usage-tui against the synthetic demo digest — run by scripts/media.sh, which
# puts a `usage-tui` on PATH that reads it, and assembles the GIF from the
# frames (this tape only captures them).
Output frames/
Set Shell zsh
Set FontSize 14
Set Width 1240
Set Height 720
Set Theme { "background": "#161618", "foreground": "#d8d8d8", "cursor": "#161618" }

Hide
Type "clear && usage-tui" Enter
Sleep 2s
Show
Sleep 3s
# The session meter's window chart: measured, then forecast.
Type "1"
Sleep 3s
Left 6
Sleep 2s
Escape
Sleep 1s
# The weekly meter.
Type "2"
Sleep 3s
Escape
Sleep 1s
# The heatmap: 7 days → 30 days → all time.
Type "v"
Sleep 2500ms
Type "v"
Sleep 2500ms
Type "v"
Sleep 1500ms
Hide
Type "q"
