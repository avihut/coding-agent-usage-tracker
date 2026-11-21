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

The pane shows the account the engine focuses, and switches it the way the
menu bar does: `a` pins focus on the next account, `A` hands it back to
activity (the panel strip's Auto), and a click on another harness's mark
in the header pins that harness's account. It is the engine's one pin, so
the menu bar follows, and the header says `pinned` while it holds. `a`
steps only through accounts the engine will focus — turned on, not
dormant, harness shown — and the footer calls a switch done only when the
digest shows it.

`usage-tui --digest <file>` reads that file and talks to NO engine: no
command (refresh, pace, focus, dismiss, the automatic "seen" marks) unless
`--socket` names a socket too, and never `usaged ensure` either way; a key
that would send one says "no engine — this pane reads a --digest file". A demo
digest that aged past the heartbeat horizon used to read as offline and
run `ensure`, which can repoint the person's launch agent, and its keys
reached the live engine (2026-11-21).

```sh
mise run tui        # build + run in this terminal
mise run tui-test   # digest contract + layout tests
```

Consumption reads every agent at once, as the panel's Activity section
does: TODAY, the model table and the activity chart total all the
accounts on the strip (the digest's `allAgents` section), and `u`
switches to the focused account and back. The header always shows the
focused account's limits — limits never add up. Under All agents the
table is the agent ▸ model outline (`ALL AGENTS · 7D`, or `AGENTS · 7D`
where the longer title would push the column labels out): every agent
row is seated first, then the heaviest models fill what is left under
their agents, and a pane with no room to spare shows agent rows only
("+N more" in the rollup line counts every hidden row). THE DEGRADE: the
section asks for up to six rows and gives rows back — models first, then
agents, down to a single one — rather than cost the pane a section one
account's view would show (the activity chart, or MODELS itself); under
~30 columns a model's indent shrinks to one cell, and an agent name that
won't fit becomes its short name. An agent whose first scan hasn't
landed keeps a dim row, "scanning…", and the readout says "partial" —
the last word a narrow readout gives up (the active days go first, then
the count label). While NO agent is counted yet there is no total:
TODAY and the readout say so instead of showing zeros. The bars stack
in each agent's colours; the TODAY spark, the heatmap and the day drill
go neutral only when several AGENTS share them (two accounts of one
agent keep its colours, as the panel does). The day drill names its
scope in its title (the count label), a model name two agents share
carries its agent ("Other (Codex)"), and a day past the total's 8 days of
hours says so ("u: this account" reads the account's own). Hover and the
keyboard cursor hold a row by its identity, so a scan landing above it
can't move it. With one account in "all" there is nothing to total, `u`
says "no all-agents total in this digest", and the pane reads as before.

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

A host that holds its lease but hasn't rewritten the digest past the
heartbeat cutoff is BUSY, not offline (2026-11-21): the header reads
"engine busy — updating… · last update 4m ago" with the meters drawn, the
strip says `busy`, and the pane never runs `usaged ensure` for it — that
nudge is for a truly absent host. The lease probe (`state::lease_held`) is
a shared `flock` via std's `File::try_lock_shared`, the same rule and
vectors as the app's (`Tests/UsageCoreTests/Fixtures/liveness-cases.json`).
With no digest yet and the lease held, the pane says "engine busy —
starting…" instead of the launch nudge. While the digest's
`activityStatus` says `scanning`, TODAY, MODELS, SESSIONS and the ACTIVITY
chart say "scanning…" — never "0 tok", an empty chart or "no sessions
recorded yet" — and while it says `cached` their titles carry "as of
HH:MM".

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
  footer, sections drop WHOLE. A meter label too long for its column keeps
  a trailing `(window)` when four head characters still fit
  (`truncate_label`: "Claude… (5h)" / "Claude… (7d)", 2026-11-21), so two
  meters of one pool never print alike. time crate: local offset captured once
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
