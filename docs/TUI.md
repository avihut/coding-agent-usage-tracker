# The Rust TUI (usage-tui)

A face, nothing more: it reads `live-state.json`, sends socket commands,
and holds no network, no credential and no write of its own.

**Read this before** touching `tui/`.

The parity program — what the TUI still owes the menu bar app, and what
is deliberately different — is in [TUI-PARITY.md](TUI-PARITY.md). The
digest it reads is in [DAEMON.md](DAEMON.md).

## Using it

A full-screen TUI face for tmux panes (`tui/`, Rust + ratatui): reads the
engine's `live-state.json`, computes nothing, and re-plans its layout from
the pane's shape — portrait stacks the sections, landscape splits into
columns, and anything under ~10×40 collapses to a one-line strip
(`✳︎ S 34 · W 59 · F 92`). Keys: `q` quit, `r` ask the engine to refresh
(over the control socket), `?` help. Works against the app-hosted engine
or the daemon interchangeably.

```sh
mise run tui        # build + run in this terminal
mise run tui-test   # digest contract + layout tests
```

Detail surfaces open from the dashboard: click a meter (or `1-3`) for its
window chart — measured percent in braille, forecast trajectory, session
stretches, `←→` scrub, time and percent axis labels once the pane affords
them — and click a heatmap day to drill into hourly bars and per-model
rows (`[ ]` pages the calendar; everything hovers — a model row re-colors
the heatmap to that model alone, as in the app). No mouse needed: the
arrow keys drive a focus cursor across whatever is interactive — it wears
the same lift (bold + brightened color) and readouts as hover — and
`enter` opens it. For the tmux
status bar, `usage-tui --status` prints one colored segment line:

```tmux
set -g status-right '#(usage-tui --status)'
```

`NO_COLOR` switches risk to `!` markers and the heat ramp to ░▒▓█ density;
non-UTF-8 locales (or `USAGE_TUI_ASCII=1`) drop to a plain-ASCII alphabet.

The digest schema is pinned on both sides of the language boundary: the
Swift tests and the TUI's serde tests decode the same golden fixtures in
`Tests/UsageCoreTests/Fixtures/digest/`.

## Architecture and standing rules

- RUST TUI (2026-08-16 v0.67.0, phase T1; tui/ cargo crate, usage-tui):
  the dependency rule is SCOPED — UsageCore/app/usaged stay zero-dep
  Swift; the TUI carries exactly ratatui, serde, serde_json, time
  (crossterm comes re-exported through ratatui so versions can't drift),
  Cargo.lock committed, rust pinned in mise [tools] (1.95, daft-style
  minimum_release_age 7d). The TUI is a FACE: reads live-state.json +
  sends socket commands; no network, no credentials, no writes of its
  own (finding no engine it spawns `usaged ensure` ONCE — the installer
  owns the policy, tui/src/main.rs find_usaged/ensure_engine). Digest
  mirrors live in tui/src/digest.rs with #![allow(dead_code)] (mirror
  completeness over usage) and MUST decode the same goldens as
  LiveStateTests — that pair of suites IS the schema freeze from here on
  (additive-only for real now). Layout = dynamic shape math
  (tui/src/layout.rs): strip under 10 rows/40 cols, landscape at
  cols ≥ 2.1×rows, priority flow header→meters→today→models→heatmap→
  footer, sections drop WHOLE. time crate: local offset captured once
  in main() before threads (soundness gate), UTC fallback. Verify
  renders headlessly: tmux new-session -d -x W -y H + capture-pane
  (sizes 100×27, 46×30, 72×16, 46×8); raw SGR mouse bytes via
  send-keys -H exercise hover/click (hover resolves against the
  PREVIOUS frame's hit map — a frame's own map doesn't exist until its
  widgets registered). T2/T3: surfaces (meter chart via ratatui Chart
  braille + day drill) open side-by-side when landscape ≥84 cols, else
  push with ← back; heatmap weekday-true both forms, [ ]/‹›/wheel
  paging; `usage-tui --status` prints a tmux status-right line;
  NO_COLOR → style() helper strips color + `!`/`!!` markers + ░▒▓█
  density heat; ascii Glyphs alphabet via locale or USAGE_TUI_ASCII=1
  (tmux itself REQUIRES UTF-8 — a C-locale tmux pane is tmux's
  unsupported corner, not ours; digest DATA glyphs stay UTF-8).
  Redraw thrift: mouse-move repaints only when the hover target
  changed; 1s clock tick; 500ms digest stat. v0.71.0: keyboard focus
  cursor — arrows walk the hit map spatially (HitMap::spatial_next,
  center-distance with 3× off-axis penalty; ←→ stay scrub/day-step on
  detail surfaces), enter/space activates, esc dismisses cursor first;
  hover_hit holds the EFFECTIVE hot element (focus vs mouse by
  keyboard_mode = last device), so every hover treatment (readouts,
  halo) serves both devices — built because some terminals (Apple
  Terminal) never report mouse motion. v0.72.0: the halo is
  highlight_band — BOLD + fg lifted ~45% toward white (brighten();
  default-fg cells get bold alone, theme-safe); REVERSED survives only
  in NO_COLOR where bold can't carry it. Hovering/focusing a ModelRow
  filters the heatmap to that model's model_days in its ledger color
  (title gains "· <name>", readout notes the ≈35d window; prompt-dot
  cells and calendar geometry stay unfiltered). Meter chart: honest axis
  labels when the pane affords them (y top 112.5 with 12.5-step label
  slots so "50"/"100" sit at true positions; x = local-time marks,
  3 under 76 cols, 5 at/above; gated ≥44 cols × ≥9 rows). Dashboard
  sections get a blank row between them when it costs no section
  (layout::pick gapped-vs-tight). v0.76.0 (parity wave 3): the meter
  surface's span math lives in tui/src/meter.rs — Span History/Current
  (`s`; Current needs a live future reset, else the key says why), a
  digest-BOUNDED zoom ladder (`z` zooms IN one rung per press, wrapping
  at the tightest; the digest publishes ONE window per meter, so
  history is a sub-range of it — the ladder is capped by that window
  and floored at 3× the MEDIAN gap between the meter's own published
  points, because 120 points thinned over 7 days would leave a 1h rung
  empty; median, not mean, so one outage can't strip usable rungs),
  and the unreachable
  region's diagonal hatch pushed as the FIRST dataset so ratatui
  layers it behind the marks (a crossing already past hatches over
  measured time — that IS its meaning). Its `view()` is the one answer
  to "what is on screen": chart, stretch track, readout and the ←→
  scrub bound all read `view().points`, so the cursor can never reach
  a sample the span isn't drawing. `p` cycles the panel's 3/5/15m pace
  picks over the socket's setInterval (next preset ABOVE the pace in
  force, so an in-between slider value never snaps backwards). The
  digest gained `EngineStatus.forecastProfile` (additive): weekly-
  rhythm maturity, countdown phrased once in
  UsageFormatting.forecastActivation and printed by BOTH the app's 7D
  caption and the pane's (wrapped, ≤2 lines, silent once ready) — a
  machine with no profile yet publishes the FULL countdown, and only a
  pre-field engine publishes nil. VERIFY GOTCHA: BSD grep on
  capture-pane -e output goes binary-mode over braille bytes and
  silently prints no matches — pipe through `cat -v` FIRST or use
  grep -a; a zero match count there can be a false negative.
