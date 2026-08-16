# TUI ↔ menu bar parity program

Status: **WAVES 1–3 SHIPPED** (v0.73.0 / v0.74.0 / v0.76.0, 2026-08-16)
— wave 4 queued.
This file is the source of truth for the program AND the context handoff
for a fresh session: everything needed to execute lives here. Read it
top to bottom before touching code.

## How to run this program

House rhythm per version (unchanged): implement → `mise run test`
(362 Swift + 17 Rust green at v0.72.0) → sed bump
`Sources/UsageCore/AppIdentity.swift` + `Support/Info.plist` (2 hits) +
`tui/Cargo.toml` → `cargo build --release` in `tui/` (refreshes
Cargo.lock; **mise test builds only the test profile — a stale release
binary behind fresh edits burned a debug cycle once**) → `mise run app`
(bundle + sign + relaunch; the relaunch's `LaunchAgentInstaller.ensure`
sees the daemon publishing the old version and `kickstart -k`s it —
the daemon self-upgrades, verify with
`.build/debug/usage-cli daemon status`) → commit ending
"Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" → annotated
tag → `git push && git push --tags` → update auto-memory.

Two decisions the USER made at program start (2026-08-16):

- **D1 — system accent (item 8): DECIDED YES** — adopted, shipped in
  v0.73.0 (`EngineStatus.systemAccent`, app converts live
  `controlAccentColor` in dark appearance; usaged maps the
  `AppleAccentColor` global via `SystemAccentPalette`'s pinned table).
- **D2 — sessions in the digest (item 25): DECIDED (a)** — user-directed
  §10 re-amendment allowing session titles in the local-only digest.
  The amendment itself lands at wave-4 start, dated, BEFORE item 25
  builds (docs/SPEC.md §10).

### Wave → version map

| Wave | Version | Items |
|---|---|---|
| 1 | v0.73.0 | 1–9, 26–30 (layout truth, color parity, state parity) — **SHIPPED** |
| 2 | v0.74.0 | 10–15, 21–24 (activity bar chart + picker, models table) — **SHIPPED** |
| 3 | v0.76.0 | 16–19, 31 (meter-surface keys, forecast note, pace picks) — **SHIPPED** |
| 4 | v0.80.0 | 20, 25 (both need digest extensions; 25 needs the §10 amendment) |

v0.75.0 sits between waves 2 and 3: a user-reported bug (a limit at 100%
still reading "runs out soon", its crossing never recorded) fixed
engine-side in PredictionEngine + UsageFormatting.forecastCaption, so
both faces inherited it. Wave 3 and 4 shifted one version later.

v0.76.2–v0.79.0 sit between waves 3 and 4, all app-side and all
user-reported on 2026-08-16, taken first at the user's direction: the day
drill's audit chart had drifted from the meter popover it claims to speak
for (reset dashes in the system accent, no reset hover, no nub hover, no
model curves), and nothing remembered a window that sat at 100% until its
reset. v0.77.0 answers the root cause the user named twice — the two
charts were separate implementations — by extracting Charts/WindowPlot.
Wave 4 shifted three versions later.

WAVE 4 IS WHAT REMAINS: items 20 + 25 at v0.80.0. Item 25 needs the
dated, user-directed docs/SPEC.md §10 amendment written FIRST (D2 is
already decided — session titles are allowed in the local-only digest).

Verify each wave headlessly (protocol below) before shipping it.

## The fix list (nothing may be silently dropped)

Tags: [S/M/L] effort · [✓] digest has the data · [+d] additive digest
field needed · [§10] user ruling needed.

### Layout & global appearance
1. [S][✓] `heat_grid` (tui/src/ui.rs:582) manufactures `weeks_visible`
   weeks unconditionally — a tall pane renders ~60 empty dot-weeks
   before the data. Cap the grid (and the heatmap section height in
   layout.rs) at the data's real week span; reclaimed rows stay blank.
2. [M][✓] Wide-portrait tier: at cols ≥ ~84 use two columns even when
   the 2.1 aspect rule says Portrait (meters/today/models left,
   full-height capped heatmap right). Today a 95×110 pane blackens its
   right half.
3. [S][✓] TODAY section reserves more rows than it paints (~3–4 dead
   rows before MODELS beyond the intended 1-row gap). Find and fix in
   `today()` (ui.rs:491) / `wants()` (layout.rs).
4. [S][✓] Meter bars are fixed-width; scale into available row width
   like the app's full-width tracks.
5. [S][✓] Empty track `░` reads as dot spray in many fonts; use a
   quieter dim solid track.
6. [S][✓] Big percent figures: neutral/bold like the app — state color
   stays on the bar and the runs-out caption.
7. [S][✓] TODAY hourly spark: raise the per-cell width cap
   (`(width/24).clamp(1,3)` in today()) so wide panes fill.

### Color language
8. [S][+d] **(D1)** Digest gains the host Mac's system accent sRGB:
   app host reads `NSColor.controlAccentColor` (convert in sRGB
   space); usaged (no AppKit) maps the global `AppleAccentColor`
   integer via a small table (resolve exact sRGB values at build time
   by printing NSColor constants from a scratch `swift run`; fallback
   when unset = macOS multicolor default → use blue). Additive field on
   EngineStatus, e.g. `systemAccent: RGBColor?`. TUI: normal-severity
   meter fills + selected-control tinting use it; absent → provider
   accent (old digests keep rendering).
9. [S][✓] Bar fill follows the digest's per-meter `severity` ladder
   (normal=accent per item 8, warning=warning color, critical=red).
   Today the TUI only swaps color on `risk`.

### Activity section
Items 10–15 and 21–24 SHIPPED in v0.74.0. Notes worth keeping: the
bars keep full height under a model hover and dim the other bands
(the app's own split — the CALENDAR forms rescale to the model
instead, `HeatmapView.color(for:)` vs `segmentOpacity`); 30D is built
from its 30-day window padded to whole weeks with blanks, never from
a count of week rows (the old grid swept in 5 extra days); monochrome
gives each stack band its own density glyph.

10. [L][✓] **7D stacked-bar chart** — the app's signature view: per-day
    bars stacked by model in ledger colors, per-day totals above,
    weekday+date labels, today bold, ‹ paging. Buildable entirely from
    `activity.model_days` (35d of full per-model tallies). Default
    activity form for roomy panes.
11. [M][✓] **USER-CONFIRMED**: 7D / 30D / All picker — key `v` cycles
    bars(7D) ↔ calendar(30D) ↔ all-time grid, mirroring the app's
    pills (app persists the choice via @AppStorage "activityPeriod";
    TUI may keep it session-local).
12. [S][✓] Tokens ↔ Cost re-valuing — key `c` (planned in the original
    T2 spec, never shipped). Applies to bars, heat intensity, day
    drill. days/model_days carry `cost` (nil = unpriced, never 0).
13. [S][✓] Summary line for the active period: "1B tokens · 6 active
    days" (compute: sum + count days with tokens>0 in scope).
14. [S][✓] Model hover/focus filters the NEW bar chart too (heatmap
    filter shipped v0.72; same `hover_hit` plumbing).
15. [M][✓] **USER-CONFIRMED (redefined)**: the TUI day drill gets a
    chart of the drilled day in the app's NON-RING drill presentation.
    Before building: READ the app's day-drill view in
    `Sources/ClaudeUsage/Panel/HeatmapView.swift` and mirror its
    non-donut arrangement (per-model composition + the day's usage
    breakdown as the app draws it, terminal-idiomized). Data: the
    day's models from `model_days` (≤35d, labeled degrade beyond,
    already handled in surfaces.rs render_day) + `hour_days` (≤8d,
    totals only).
16. [S][+d] Forecast-maturity note ("Personalized forecast activates in
    7 days — learning your weekly rhythm") — additive digest flag for
    weekly-profile state (e.g. `profileMature: Bool?` or days
    remaining) published by the engine. **SHIPPED v0.76.0**:
    `EngineStatus.forecastProfile` (isReady / historySpanSeconds /
    remainingSeconds / pre-phrased caption), phrased once in
    `UsageFormatting.forecastActivation` — HeatmapView and the pane
    now print the same sentence. A machine with NO profile yet
    publishes the full countdown rather than nil (nil means "engine
    predates the field"). The pane wraps it under the 7D bars, ≤2
    lines, and goes silent once ready.

### Meter detail surface
17. [M][✓] Span picker `s` — Sliding/Window (from the unshipped T2
    line). Digest series is window-scoped; sliding = trailing tail of
    the same series. Mirror the app's popover semantics
    (`Panel/MeterHistoryView.swift`). **SHIPPED v0.76.0** in
    `tui/src/meter.rs`; Window needs a live future reset, else the
    key says why (the app hides its picker in that case).
18. [S][✓] Zoom `z` (same unshipped plan line; see MeterHistoryView
    for what zoom means there — the SlidingFrame dropdown).
    **SHIPPED v0.76.0**, corrected v0.76.1: `z` zooms IN one rung per
    press (wrapping back out at the tightest), and from the Window
    span drops to Sliding first — so every press changes the view and
    the FIRST press is always the useful one. Ladder deviation is
    deliberate — see #33.
19. [S][✓] Hatch/dim the unreachable region beyond the projected
    exhaust crossing (app hatches; TUI has only the red mark —
    forecast.exhaustAt is in the digest). **SHIPPED v0.76.0**: a
    diagonal stripe dataset pushed FIRST (ratatui layers datasets, so
    first = behind the marks, as the app draws it behind its curves),
    dim red, sparser under NO_COLOR. A crossing already in the past
    hatches over measured time — that is what it MEANS ("from here
    you were out"), not a bug to fix.
20. [L][+d] Per-model cumulative curves + breakdown legend under the
    meter chart (the app popover's centerpiece; the deferred "v2"
    item). Needs an additive digest extension: per-model window series
    per meter. Design the schema addition first (additive-only,
    golden-fixture discipline).

### Models / cost section
21. [M][✓] MODELS follows the activity period (today it's today-only
    and missed 2 of 4 models vs the app's 7D table). Build rows from
    `model_days` for the active period.
22. [M][✓] Token split columns when width affords: input / cached /
    output / est. cost (Tally carries input, output, cacheCreation,
    cacheRead; app shows cache re-reads apart from fresh input).
23. [S][✓] Period cost rollup line: "≈ $1,308 at API list prices".
24. [S][✓] Money/"—" formatting parity with the app everywhere
    (unpriced → "—", never $0).

### Sessions
25. [L][+d][§10] **(D2)** Sessions shortlist section in the TUI
    dashboard (the deferred v1.5 item): recent sessions with cost,
    start · duration, model dots, tokens, prompts, calls — plus title
    or project·branch per the D2 ruling. Requires: additive digest
    section (engine publishes from its session index), Rust mirrors,
    layout slot, golden regen. If D2=(a), amend docs/SPEC.md §10 with
    a dated user-directed line first.

### Header / footer behavior
26. [S][✓] "idle ×N" cadence indicator from `paceMultiplier` when >1.
27. [S][✓] Backoff countdown mm:ss from `backoffUntil` (app shows the
    retry countdown; TUI has only the state dot).
28. [S][✓] Render the digest's typed error text (ErrorStatus code +
    message) as readable header copy, like the app's error states.
29. [S][✓] Render SpendStatus (extra-usage spend line) — digest
    carries it, TUI ignores it.
30. [S][✓] Color the header's `API n/Nh` from `apiBudgetFraction`
    (orange approaching, red at ceiling — app's refresh-button
    grammar).
31. [S][✓] Quick pace presets — key `p` cycles 3/5/15m via the
    socket's `setInterval` (works against app-hosted and daemon —
    both run the socket). **SHIPPED v0.76.0**: `socket::set_interval`,
    `state::next_pace` picks the next preset ABOVE the pace in force
    (a slider-set in-between value never snaps backwards to 3m). The
    engine persists it exactly as the ⋯ menu's picks do.

### Intentionally different (do NOT "fix")
32. Push/pop animation, pointer cursors, hover popovers — GUI idioms;
    surfaces/instant swaps are the terminal equivalents.
33. The zoom ladder (v0.76.0/.1). The app's frames are 5h/12h/24h/wk/
    7d/30d because it holds 56 days of samples; the digest publishes
    ONE window per meter, so the pane's Sliding span can only ever be
    a sub-range of that window. The ladder is therefore bounded at
    BOTH ends by the digest: capped by the meter's window (wider would
    render emptiness — a 5h session meter stops at 5h) and floored at
    3× the MEDIAN gap between that meter's own published points
    (v0.76.1), since 120 points thinned across a 7-day window land far
    enough apart that a 1h rung would open on an empty plot and read
    as broken. Median, not mean: one multi-hour outage skews the mean
    and would strip usable rungs. On this machine the weekly meters
    (median gap ~34 min) offer 2h upward, the session meter (~3 min)
    the whole ladder. Hence 1h/2h exist at all, below where the app's
    ladder starts. The calendar-anchored `wk` frame has no counterpart
    at all: it is anchored to the week, the series to the window, so
    it could only mislabel a partial slice.

## Context a fresh session needs (do not rediscover)

### Repo + versions
- daft contained layout; worktree `~/Projects/claude-usage-menubar/main`
  (NOT a plain git repo root — `.git` is bare at the project root).
- Current: v0.72.0 shipped, tagged, pushed. Daemon (usaged) runs live
  on this machine, self-upgrades on every `mise run app` via
  LaunchAgentInstaller.ensure's version-kickstart. Auto-install is in
  force (§10 re-amended 2026-08-16); sticky opt-out `daemonAutoInstall`.
- Tests at v0.76.0: 365 Swift (`swift test`) + 28 Rust
  (`cd tui && cargo test`); `mise run test` runs both. NOTE: clippy
  and fmt are NOT gated by `mise run test` and the crate carries
  pre-existing drift in state.rs/status.rs/ui.rs/main.rs/activity.rs —
  don't sweep it into a feature commit.

### Digest (the only data source the TUI may use)
- Schema: `Sources/UsageCore/Digests/LiveState.swift` (+ builder),
  published by `Engine/StatePublisher.swift` at every landing point to
  `~/Library/Application Support/com.avihu.ClaudeUsage/live-state.json`.
- FROZEN, additive-only. Golden fixture
  `Tests/UsageCoreTests/Fixtures/digest/live-state-v1.json` is decoded
  by BOTH LiveStateTests (Swift) and tui/src/digest.rs serde tests.
  Regen: `UPDATE_GOLDENS=1 swift test --filter LiveState`. Rust
  mirrors ignore unknown fields → old TUIs tolerate new fields; new
  TUI must treat every new field as Option (absent ≠ zero — nil is
  NEVER rendered as 0).
- Available now: meters[] (tag/label/percent/severity/risk RGB/resets/
  captions/forecast{curve ≤48, series ≤120 window-scoped, stretches,
  projectedAtReset, exhaustAt}), engine (plan facts, host, pid,
  generatedAt/fetchedAt/nextPollAt, backoffUntil, stale, error
  {code,message}, spend, apiBudget{used,ceiling,fraction},
  activeIntervalSeconds, paceMultiplier, accent RGB, glyph,
  isLocalProvider), models[] (TODAY-scoped: id/displayName/color
  RGB/tally 4-way/cost?), activity (todayHours 24×{tokens,cost} —
  TOTALS ONLY, no per-model hourly; days ~366d totals; model_days ~35d
  of {dayKey, models[] with full tallies}; hour_days ~8d; timeZone),
  menuBar segments.
- NOT available (hence [+d] items): per-model window series per meter
  (20), sessions (25),
  per-model HOURLY buckets (why today-spark stacking is impossible —
  do not attempt).

### TUI code map (tui/, ratatui 0.30.2, rust 1.95 mise-pinned)
- main.rs: event loop (1s tick, 500ms digest stat, 100ms poll), keys
  (q, esc-chain: help→cursor→scrub→surface→quit, enter/space
  activates `hover_hit`, r=socket refresh threaded via reply channel,
  1-4 meters, tab, [ ] page, arrows, **v period, c dimension**),
  `focus_move` (keyboard cursor), `find_usaged`/`ensure_engine`
  (auto-install nudge, once, when EngineOffline). v0.76.0 added
  **s span / z zoom** (meter surface only — on the dashboard they
  say "open a meter first") and **p pace** (3/5/15m over the socket).
  FREE KEYS still: m, d.
- activity.rs (v0.74.0): the period math — `span`, `day_value`,
  `model_totals`, `active_days`, `total_value`, `segments`,
  `model_horizon_truncates`. Pure, tested; every activity surface
  reads it so table, chart and summary can't disagree.
- meter.rs (v0.76.0): the meter surface's span math — `Span`
  (Sliding/Window), the `FRAMES` ladder + `ladder`/`default_rung`
  (window-capped), `window_available`, `view()` (start/end/label +
  the CONTIGUOUS slice of series points on screen) and `hatch()`.
  Pure, tested; the chart, stretch track, readout AND the ←→ scrub
  bound all read `view().points`, so the cursor can never land on a
  sample the span isn't drawing (the desync this module exists to
  prevent). Per-meter span+rung live in `App.meter_span` for the run
  — the pane persists nothing.
- state.rs: App (digest, freshness via broker heartbeat rule, surface
  Dashboard/Meter(usize)/Day(String), heat_page, scrub, pointer,
  hover_hit = EFFECTIVE hot element (mouse vs keyboard focus by
  keyboard_mode = last device), focus_hit, HitMap {at, rect_of,
  spatial_next — doubled-coord centers, along + 3×across score}),
  Look{no_color, ascii} OnceLock.
- ui.rs: render() resolves hover/focus against the PREVIOUS frame's
  hit map, then clears; halo = `highlight_band` (BOLD + fg lifted
  ~45% toward white via `brighten`; default-fg cells bold-only;
  NO_COLOR keeps REVERSED); dashboard sections; heatmap (portrait
  weeks-as-rows / landscape weekday-letter strip, `heat_grid` at :582
  = the item-1 bug, model-filter via hover_hit ModelRow → heat_tokens
  from model_days in ledger color, title "ACTIVITY · <name>", readout
  ≈35d note); `today()` at :491; `style()` = the NO_COLOR choke point
  (NEVER blanket-sed a call pattern into a helper's own body — the
  v0.69 self-recursion spin); Glyphs alphabet (UTF-8/ASCII).
- layout.rs: Shape strip(<10r|<40c)/landscape(cols≥2.1×rows)/portrait
  + wide-portrait (≥84 cols, v0.73.0); plan() = pick(gapped, tight) —
  1-row inter-section gap only when it costs no section
  (landed-count). **plan() now takes each section's TRUE row count**
  (meters incl. credits line, models incl. rollup, activity per its
  form), computed by `Dash::build` in ui.rs — the layout guesses
  nothing and reserves no row that goes unpainted.
- surfaces.rs: render_meter (braille Chart, forecast dots, now marker,
  axis labels: x local-time marks gated ≥44c×≥9r, y top=112.5 with
  12.5-step label slots — ratatui spreads labels EVENLY over bounds,
  keep labels honest), stretch track, render_day (hourly ≤8d +
  models ≤35d with labeled degrade), neighbor_day, split_viable
  (landscape ≥84 cols side-by-side, else push with back).
- socket.rs: NDJSON one-shot; `refresh` + `set_interval` (wire shape
  `{"setInterval":{"seconds":300}}`, reply {ok,message} — verified
  against the live daemon).
- status.rs: --status tmux line.

### App-side reference code (READ these to copy presentation)
- `Sources/ClaudeUsage/Panel/HeatmapView.swift` — 7D stacked bars,
  30D calendar, All grid, the period picker (@AppStorage
  "activityPeriod", default .week), Tokens/Cost toggle, and THE DAY
  DRILL (item 15's model — mirror its non-ring presentation).
- `Panel/MeterHistoryView.swift` — popover chart: span picker
  semantics (Sliding/Window), zoom, hatched unreachable region,
  per-model cumulative curves (item 20's model), per-interval
  readouts, breakdown-legend interplay.
- `Panel/UsagePanelView.swift` — panel assembly, shortlistRow hover
  grammar (6% primary fill; sessions window copied it in v0.72).
- `Panel/MeterRow.swift`, `Panel/RiskColor.swift`,
  `Formatting/RiskRamp.swift` (pinned yellow→red ramp),
  `Activity/ModelColorLedger.swift` + ModelColorMath (ledger colors —
  the digest's RGB already comes from here; TUI must NOT re-derive).
- `Sessions/SessionRow.swift` + `SessionsView.swift` (item 25 card
  content), `Store/UsageStore.swift` (host/client modes),
  `Sources/usaged/main.swift` (daemon; defaults: embedded → .standard,
  bare → suite — the v0.70 crash lesson).

### Engine-side touch points for [+d] items
- Extend LiveState structs + LiveStateBuilder.build(...) signature +
  the engine's publish call sites (UsageEngine publishState) + Rust
  mirrors + BOTH golden suites in one change per field. Bump nothing
  in the schema version (additive), regen goldens, run both suites.
- Item 8 host plumbing: UsageEngine has `host: .app|.daemon`; the
  ACCENT must come from the host process (app: AppKit; usaged:
  defaults global read). Simplest: a `systemAccent: RGBColor?`
  parameter injected at engine init (app passes converted
  controlAccentColor; usaged passes table-mapped AppleAccentColor),
  re-read on thresholdsChanged/settingsChanged for live accent
  switches (nice-to-have; launch-read is acceptable).
- Item 25 (if D2=a): amend docs/SPEC.md §10 FIRST (dated,
  user-directed), then publish a sessions shortlist (the engine
  already owns the session index via providers' scans).

### Verification protocol (hard-won — follow exactly)
- Headless renders ONLY via tmux: `tmux new-session -d -x W -y H`
  + `capture-pane -p` (plain) / `-p -e` (attributes). Reference
  sizes: 100×27, 46×30, 72×16, 46×8; ADD a tall-narrow ~95×110 case
  for items 1/2 (the user's actual pane).
- Attribute forensics: this user's shell aliases grep→ugrep AND \[
  escaping through $("") mangles patterns — use `/usr/bin/grep` on a
  `cat -v`'d FILE, or just eyeball raw rows with `sed -n Np`. Direct
  evidence over counts (two false negatives happened).
- Mouse: raw SGR bytes via `tmux send-keys -H` (paste-buffer mangles
  them). Keyboard: plain send-keys works (arrows included).
- Non-TTY stdout = 0×0 crossterm size → file-redirect "renders" are
  blank; never verify that way.
- Rebuild `cargo build --release` BEFORE every tmux verification.
- Headless focus tracing: temporarily write into `app.notice` (renders
  in footer), remove before commit.
- The daemon publishes ~live data constantly; `--digest <path>`
  + crafted fixtures for state-specific renders (backoff, error,
  spend) — don't wait for real 429s.
- NO_COLOR + USAGE_TUI_ASCII=1 passes for every new visual (halo stays
  REVERSED in NO_COLOR deliberately).

### Standing rules that bind this program
- Digest additive-only; absent ≠ zero; cost nil ≠ $0.
- §10: no credentials/full paths/prompt text/session titles (until
  D2) in the digest; TUI computes nothing, fetches nothing, holds no
  credential; single-writer = lease holder.
- Zero-dep rule is SCOPED: Swift targets zero-dep; TUI exactly
  ratatui/serde/serde_json/time (crossterm via ratatui re-export). No
  new crates for this program.
- Never poll faster than 180s; TUI `r` goes through the gate.
- Every version: annotated tag, pushed. Memory updated per version.
- App is personal, not distributed; never run synthetic UI clicks
  while the user actively uses the app.
