# Charts and the activity surfaces

Every plotted surface in the app, and the standing contract any new one
inherits by construction rather than by reimplementation.

**Read this before** adding or changing any chart, the heatmap, the meter
popover, the audit views, or a model-colour decision.

Per-harness marks, accents and the group geometry of a multi-harness bar
are in [HARNESSES.md](HARNESSES.md); how the numbers behind these plots
are produced is in [MEASUREMENT.md](MEASUREMENT.md).

## The chart behavior contract

- CHART BEHAVIOR CONTRACT (2026-08-15 v0.32.0, user-directed standing
  rule): any surface that plots a running/cumulative series over an
  event list renders `RunningBreakdownChart`
  (Sources/ClaudeUsage/Charts/) fed by a core `SessionChartModel`
  (per-row carry-forward cumulative arrays for O(1) hover lookup;
  per-model series with cost NIL for unpriced models — never a flat $0
  line; promptRows; prompt-to-prompt Sections with per-measure
  subtotals). These behaviors are the contract — future graphs of this
  shape ship them by construction, not by reimplementation:
  (1) Cost/Tokens SegmentedPicker + series total in the header, no
  title copy; (2) vertical marker lines at every prompt with ~4pt snap
  — and compactions as DASHED primary rules (v0.33.0, the meter reset
  idiom: same semantic, a context reset; never accent, no snap);
  snapping (or hovering that prompt's list row) lights the whole
  section by CURTAINING everything outside it (windowBackgroundColor
  0.5 — the meter-popover idiom: the highlight is everything else
  dimming), section subtotal annotated in the headroom band; (3) plain
  hover = quaternary crosshair + dot + a fixed-height readout line that
  never reflows, mirrored onto the list through ONE shared hoveredRow
  binding (both directions — list rows hover too); (4) per-model
  overlay curves in ModelPalette colors; curve-proximity focus (8pt
  grab) meets the breakdown grid's row hover in the shared hoveredModel
  binding — focused curve drawn last, peers dim to 0.15, name at tip;
  (5) click → onSelectRow → ScrollViewReader scrollTo(.center) + an
  accent flash that eases out; (6) the x-axis is EVENT ORDINAL, not
  time — sections stay visible across idle gaps and hover maps 1:1 to
  rows; marks thin (240 total / 120 per model) but hover reads FULL
  arrays; (7) the chart endpoint MUST equal the surface's headline
  total (see RECONCILIATION); (8) a CTX button-toggle (v0.42.0,
  @AppStorage "sessionsShowContext", rendered only when
  SessionChartModel.contextFraction is non-empty) overlays each
  call's context share — inputSide / its OWN model's window, built
  from a windows map passed to build(), carry-forward, EMPTY (not
  all-zero) when no window is known — as a dashed secondary curve
  scaled to the plot ceiling (full context = data ceiling, honest in
  both measures), "context N%" at the tip, hover readout appending
  "· ctx N%"; a gauge, never a model color; (9) pinch zoom (v0.59.0,
  panning fixed v0.60.1) is X-ONLY — MagnifyGesture drives a
  visibleLength/scrollX pair (anchor-stable: the event under the
  fingers stays put; snap-out at ≥98% of full), THE ZOOM IS THE X
  DOMAIN (chartXScale reads xDomain; plot .clipped()); panning is a
  HorizontalPanCatcher feeding scroll deltas converted to data units
  (Charts' .chartScrollableAxes never responded to trackpad scrolls
  here — don't go back to it), momentum included; a ChartMinimap strip
  (total hairline + viewport box) appears above only while zoomed,
  fading while the layout animates its slot; zoom-presence FLIPS run
  through setZoom's withAnimation transaction (v0.62.0) so siblings
  BELOW the chart (divider/header/table) slide too — a body-scoped
  .animation(value: visibleLength == nil) alone animates only the
  chart subtree and the table jumps; in-zoom pinch ticks stay
  transaction-free to track fingers; minimap dragging
  is GRAB semantics (v0.60.2): press captures the viewport's start
  fraction, drags move it RELATIVELY — never teleport-to-pointer, a
  plain click moves nothing; hover lights the strip, pointer
  .grabIdle/.grabActive; the pane keys the chart .id(session.id) so
  zoom dies on session switch but survives live re-parses. Y NEVER zooms. Hover/annotation idioms (onContinuousHover plot-frame math,
  .fit(to: .plot) overflow, hover cleared on exit) stay consistent
  with the meter popover chart.

## Chart mark colors

- CHART MARK COLORS: inside a `Chart`, ALWAYS spell it `Color.primary` /
  `Color.secondary` / `Color.quaternary`. The bare hierarchical `.primary`
  does NOT mean the label color there — it resolves against the plot's own
  foreground, i.e. the accent. v0.76.2 (be917c5): AuditWindowChart's reset
  dashes and strip track came out in the system accent (purple on this
  Mac) while MeterHistoryView's identical marks, spelled `Color.primary`,
  stayed white — user-reported as "the reset dashed lines are in a
  different color", and a violation of the contract's clause (2) "never
  accent". Verified with a headless ImageRenderer probe: `.primary`
  sampled (0.00, 0.62, 1.00), `Color.primary` sampled the label color.
  Bare hierarchical styles on a Text INSIDE an annotation are fine — it's
  an ordinary view. Still spelled the bare way, deliberately unreported
  and left alone: MeterHistoryView's now rule (:554) and readout crosshair
  (:645), RunningBreakdownChart's hover crosshair (:412).

## Curves begin where usage begins

- CURVES BEGIN WHERE USAGE BEGINS (2026-09-03, user-directed, ALL model
  charts): a model adopted mid-span draws nothing before its first tokens —
  its curve starts at the ONE zero it rises from (the boundary of the first
  bucket that held tokens / the row before the first call), never a flat
  zero leader back to the span's start, which read as "this model sat at 0
  the whole time". Time-based curves get this from `CumulativeSeries.build`
  (so the popover, the audit chart, AND the digest's `modelSeries` for the
  TUI agree — the golden fixture was regenerated); a model idle across the
  whole span keeps its `ModelCurves.Curve` entry with NO points (legends
  still name it, nothing draws). Row-based series
  (`SessionChartModel.ModelSeries`) stay row-aligned for O(1) hover but
  carry `firstRow`/`drawStart`; `RunningBreakdownChart` pins `drawStart`
  into its thinned index set so the rise is never strided away. Hover
  focus honours it everywhere: `interpolate` returns nil before a curve's
  first point, the audit and session focus loops skip a curve before it
  begins — nothing undrawn can be grabbed.

## The limit-window plot

- LIMIT-WINDOW PLOT: `Charts/WindowPlot.swift` (v0.77.0, 7cf5180) is the
  ONE vocabulary for the percent-over-a-span charts — reset dashes, reset
  curtain, nub curtain, `Nub` (start/end/kind/fullStart), nub colour +
  hover opacity, reset hit-testing — exposed as composable
  `@ChartContentBuilder` pieces. `MeterHistoryView` (live popover) and
  `AuditWindowChart` (read-only day/week audit) BOTH draw through it; a
  new behaviour goes here, never into one chart. User-directed after they
  twice reported the two charts drifting apart ("it's like the component
  is not reused properly or at all"). Deliberately NOT shared, since
  unifying would change what ships in one of them: the y-scale (popover
  scales from the tallest model curve, +15% headroom band; audit chart
  pins 0…100) and the strip geometry (band vs round-capped rule); also
  `liveNub`'s midpoint re-anchoring, which only the popover's re-anchoring
  sliding domain needs. Curtains stop at y=0 so the strip dims by its own
  opacity, never twice. v0.82.0 (1b42044): `marking` hands the WHOLE strip
  to `ExhaustedStretches.mark` in one call (per-nub calls file each
  remembered spent span once per nub, and none over a quiet strip;
  spans-file-once is core-tested), and `liveNub` resolves by midpoint
  containment among SAME-KIND segments (nearest-peer fallback only for
  exhausted, whose forecast boundary drifts) — "first exhausted" let a
  ~1-min remembered sliver at the window's left edge (prev window closed
  pegged; detected cliff lags resets_at by a sample cadence) hijack the
  forecast nub's hover into a corner-pinned red "1 min".

## Limit-window paging

- LIMIT-WINDOW PAGING (2026-09-04 v0.91.0, user-directed): the popover's
  Current span pages back through the meter's PAST windows — ‹ › arrows
  flanking the bounds row, a skip-to-live button after ›, and a two-finger
  horizontal swipe (`HorizontalSwipeCatcher` on the chart; enabled only on
  Current). Pages are `LimitWindows.observed` (UsageCore/Audit, tested):
  strictly the windows this Mac SAW — reset stamps carried by the percent
  samples (`UsageSample.resets`) plus the window ledger's closes, jitter-
  collapsed through `ResetStamp`, live stamp and future stamps excluded,
  newest first; a stretch the app slept through is a gap, never a
  cadence-guessed page. `windowOffset` state (clamped to the pages that
  exist via `pageIndex`; reset on meter switch and on a span flip); `isLive`
  gates everything only the live window has — now rule, forecast
  trajectory, crossing hatch, axis projection, predicted readouts, the
  strip's hold-open. A past page's table and totals are bounded by the
  PAGE's end (`windowRows` to: min(domain.end, now) — summing to now made
  a week page and a 5h page read identical). Labels: the stats line
  becomes the page TITLE in primary semibold ("Sun Aug 23 · 13:30–18:30 ·
  10 sessions ago"; weeks "Aug 23 – Aug 30 · previous week"), the header
  stays identical to the live page's, every row keeps its height (arrows
  reserved at zero opacity on the live page and on History); bounds and
  readouts on a past page always carry month + day (`timeLabel`). Page
  turns slide the chart (`.id(pageIndex)` + asymmetric move transition,
  earlier pages arrive from the left; animation scoped to the chart
  subtree so the grid below resizes discretely). TUI parity deferred.

## Axis label eclipse

- X-AXIS ECLIPSE (2026-09-20, user-reported on a Codex card; older than
  the branch it surfaced on): a time-axis tick label HANGS RIGHT of its
  gridline, it is not centred on it — `tickLabelEclipsed` measured centred
  extents, so it silenced a clear label and kept the one the red crossing
  stamp then overprinted; base labels are `fixedSize` so the frame's last
  one no longer truncates at the plot edge ("S…").

## The heatmap, the breakdown grid and the meter popover chart

- THE ACTIVITY SURFACES (continues the scan described in
  [MEASUREMENT.md](MEASUREMENT.md#the-transcript-scan)):
  Day tooltips stay a
  one-liner by request; the per-model detail lives in the meter popovers
  and the period summary. That summary is a tabular grid (aligned
  input/cached/output/cost columns — `uncachedInput` vs `cacheRead`,
  split because agentic harnesses re-read the whole conversation from
  cache every request, and lumping that into "input" misreads as typed
  prompt volume) doubling as a legend: model colors are app-wide and
  persistent — `ModelPalette.assignment` is the ONLY source; a
  UserDefaults-backed `ModelColorLedger` (UsageCore, pure, tested)
  gives each model FAMILY a base hue and each version within it a
  shade of that hue (kin at a glance, discernable apart), lowest free
  slot on first sight, kept forever — the launch scan seeds heaviest
  first so the heaviest family wears Claude orange. Hovering a row filters the chart to
  that model (heatmap re-ramped against `HeatmapLayout.modelMaxTokens`,
  its busiest own day, so light models keep contrast), the 7D bars are
  per-model stacked with band order fixed period-wide, and clicking any
  day pushes (animated, with a back button) into a per-day drill-down —
  model donut + the same grid scoped to that day. The grid is one shared
  component (`ModelBreakdownGrid`), also the meter popovers' table;
  clicking a row pops the cost math (`ModelRates.components`, the single
  costing source `dollarBreakdown` sums over: tokens × $/MTok per token
  class, 5m/1h cache-write split, `*` on fallback rates). The
  popover chart overlays the meter's percent line with EVERY model's
  cumulative token curve, all through ONE shared conversion
  (percentPerToken = the window's percent GAINS / its total tokens —
  `ModelCurves.windowPercentPerToken`, the window entering at zero, drops
  excluded; v0.99.1, user-reported: end-minus-start under-priced every
  token by the share spent before a vendor grant, so a scoped meter's one
  model drew below its own percent line until the window's end) so the
  models' combined spend meets the percent growth exactly and no token
  curve towers over the usage that contains it — except across a grant,
  where the forgiven spend still happened: `ModelCurves.holdsGrant` lifts
  the Current span's cap and the curve tip stays the window's token total
  (fallback: busiest-model spans the plot, only when percent data is
  missing/flat);
  one `focusedModel` state drives both the chart (focused curve full
  opacity + area, rest dimmed) and the legend rows — hover either surface
  and both light, since they render from the same binding. While focused,
  the Y axis re-labels its same gridlines as tokens (percent ÷
  percentPerToken) at one fixed label width — the mode flip must never
  resize the plot — and the model's name rides above its curve tip in
  its color. Chart labels are LAYERED: strip duration > focused-model name >
  now — lower layers disappear while an upper one overlaps
  (nowEclipsed's track-space estimate). A
  History|Current span picker (hidden without a live reset; choice
  persisted per meter via @AppStorage `meterPopoverSpan-<id>`, since the
  shared popover would otherwise leak one meter's choice onto the next)
  switches the X domain between trailing-now and the limit window
  start-to-reset; the
  Current span draws a 30s-ticking vertical now rule (labeled with the
  clock time — all axis/annotation labels on this chart are semibold) and
  the prediction engine's dashed trajectory in the risk ramp color, and
  hover readouts right of it report
  "proj. N%" off that curve. When the pace spends the limit before reset,
  a red rule marks the crossing and a Canvas in chartBackground hatches
  the unreachable region diagonally; the crossing's timestamp sits
  ALWAYS-ON in red in the X axis row — base ticks it would overlap
  silence their LABEL only, never their gridline (`tickLabelEclipsed`,
  `xAxisClearanceFraction` 0.15 of the domain,
  reach shifted with the label's edge-aware anchor + `fixedSize` so it
  never truncates at a plot edge; the Y-axis projection eclipse keeps
  gridlines the same way — eclipse rules on EVERY axis blank labels,
  not marks), and sub-48h frames swap automatic
  hour ticks for explicit ones while a crossing exists, since automatic
  marks can't be eclipsed.
  Chart annotation labels must neither escape the chart nor sit on the
  data. Hover-only labels fit INTO the plot (`overflowResolution`
  x/y `.fit(to: .plot)`). Top-of-chart labels
  get reserved room INSTEAD: the Y domain extends above 100
  (plotCeiling, the strip trick mirrored upward) and the now /
  session-duration labels live in that headroom band — their rules and
  the hover crosshair stop at y 100, y-fitting disabled. Three failed
  shapes, don't repeat them: no headroom crashed the label into the
  stats line; y-fit dropped it onto the curves; `chartPlotStyle` top
  padding shifted the plot against its own axis marks. All spans carry an iStat-style activity strip: a
  band below the plot floor (chart Y domain extends to −8; AreaMarks pin
  yStart: 0 so fills don't bleed into it) — orange segments where
  transcripts logged tokens, faint track otherwise, scoped meters
  counting only their own model. Idle gaps within the grace period
  (`ActivityGrace.stitch`, default 15 min, Settings → General slider
  down to off) are bridged — the user pausing to read or reply is still
  the same session; the raw runs show only at 0. The newest stretch is
  held open to now while its idle time is still within grace
  (`ActivityGrace.holdOpen` — the session may yet continue), snapping
  back to its true end once the gap outgrows the grace; the hold caps
  at the exhausted boundary so nubs never overlap the red strip. Hovering below the plot floor hands the
  hover to the strip: the nub brightens, its peers recede, dimming
  curtains (windowBackgroundColor 0.5) cover the graph outside the
  hovered slice — the undimmed slice IS the highlight — the session's
  duration shows semibold in the headroom band centered over the nub
  (the now label yields the band), the readout line reports the
  stretch's range and duration, and the breakdown grid re-tallies to
  just that session (row set/order fixed — hover never reflows — silent
  models read zero); curve focus and point readouts stand down there. Nub hover state re-anchors onto each render's fresh
  segments via liveNub — the stored nub's midpoint finds the live
  segment containing it; exhausted matches by kind — because NO date
  field on a segment is comparison-stable: the sliding domain
  re-anchors at Date() on every render (shifting every bucket
  boundary) and the trailing end / exhausted start move with time.
  Matching by equality or by start orphaned the hover (muted or
  unhighlighted nubs). The dead stretch past the exhaustion
  crossing gets a red nub of its own ("unreachable" in the readout).
  Segmented pickers are built ONLY through the shared `SegmentedPicker`
  (Sources/ClaudeUsage/Components/SegmentedPicker.swift — mini/bare/semibold, one
  place for the style; settings panes pass size: .regular). Hover-driven stats lines are fixed-height by
  design — swapping text must never reflow the layout under the cursor —
  and today's cell/bar carries a subtle ring (grids only — the 7D bar's
  bold weekday label suffices). A Tokens|Cost segmented picker beside the
  period picker re-values every chart surface (cell intensity, bar
  heights/segments/labels, tooltips, stats line, drill ring) via
  `CostIndex` — per-day cost prebuilt next to the layout so render
  passes never price models; unpriced models drop out of cost mode.
  The 7D and 30D periods page whole windows into the past with
  drill-down-style ‹ › chevrons FLANKING the chart (`HeatmapLayout.build`
  `pagesBack` + `hasOlder`; All shows everything and renders none): ‹
  enables while older activity exists, › while off page 0 — an
  unavailable direction keeps its reserved 17pt at zero opacity, because
  page flips MORPH the chart IN PLACE (user-specified: no slide, and the
  same feel as the Tokens↔Cost flip — bars glide, cells re-tint). The
  morph rides on identity: the 7D bars/labels ForEach by POSITION
  (`days.indices`), never by day — day identity tears the row down and
  snaps; day numbers and bar value labels roll via
  `.contentTransition(.numericText())`. The animation is SCOPED, not
  withAnimation around the state change: `.animation(drillAnimation,
  value: pageTick)` on the arrow-chart-arrow HStack only, where pageTick
  is bumped solely by the arrows — because everything outside (the
  summary grid's row count differs per window) must step DISCRETELY so
  the popover resizes once natively instead of chasing an animated
  height per frame (user: height jumps = janky; same lesson as the
  drill). Chart heights are page-invariant by construction: bars sit in
  a fixed frame and the 30D calendar pads to a constant 6 week rows
  (`monthRowCount`; a 30-day span needs 5 or 6 depending on start
  weekday). Empty windows NEVER swap the section away: the bare
  "No local Claude Code activity found" view renders only at page 0 with
  layout.isEmpty and !hasOlder (nothing to navigate to) — otherwise an
  empty page keeps the full chart (date labels, stubs, arrows; layout
  builds all date cells regardless of activity) with a centered
  "No activity in this window" overlay, so paging onto a quiet week
  never strands the user (it used to drop the arrows entirely).
  Live-refresh and period-switch rebuilds leave pageTick alone (those
  snap). The stats line prefixes the visible range ("Jul 27 – Aug 2")
  when paged; panel close and period switches reset to page 0. The 7D bars carry the
  typical-week overlay: the weekly meter's
  `WeeklyProfile.weekdayShares()` stretched over the displayed week's own
  total (dashed primary polyline + dots, hit-testing off) — built from
  `TrendGeometry`, a Shape whose `animatableData` is an
  `AnimatableVector` of per-day height fractions, NOT a Canvas (a Canvas
  snaps to the finished frame; the Shape bends with the bars) — so it
  works in tokens or cost mode and on past pages; DIRECTLY under the bars (above the table) a caption either
  legends the overlay or counts down ("Personalized forecast activates in
  9 days") — the same countdown shows concretely in Settings → Usage,
  falling back to the raw sample span before the profile object exists.

## The window ledger and the audit views

- WINDOW LEDGER + AUDIT VIEWS (v0.55.0/v0.58.0, user-directed — the
  limit history had to be auditable "including seeing if the limit was
  reached"): `WindowLedger` (UsageCore) records each CLOSED limit
  window's outcome —
  `WindowOutcome{meterID,label,end,start?,lastPercent,peakPercent,
  recordedAt}`, id = meterID|end-epoch. Detection is OBSERVATIONAL:
  `closedWindows(previous:current:samples:now:)` fires when a meter's
  reset stamp rolls FORWARD between consecutive snapshots (previous may
  be the cached one — still an observation); windows that come and go
  while the app is off stay unrecorded, never guessed. peakPercent =
  max(in-window samples by LABEL — the UsageSample key — floored at
  lastPercent); `reachedLimit` = an observed 100, false means "not seen
  hitting it". Store closes out BEFORE history.append (samples as they
  stood while the window ran), persists provider-scoped
  `window-ledger.json` (append, id-dedup, kept indefinitely — tiny),
  publishes `store.windowOutcomes`. Consumers: the AUDIT VIEWS
  (v0.58.0) — `AuditWindow.build` (UsageCore, tested) assembles a
  historical span the way the meter popover assembles its live window
  (label-scoped percent series entering at height, ResetCliffs pairs
  with currentReset nil, session-stretch nubs clipped+merged, in-span
  outcomes) and `AuditWindowChart` (Charts/) renders it read-only
  (percent line, dashed cliffs, floor strip, hover crosshair,
  fixed-height verdict caption). A span that CONTAINS now — today's
  drill, the current week — is LIVE (v0.92.2, user-reported: curves ran
  flat to midnight and no now rule): model curves and the strip track end
  at now, a primary now rule with its clock label in the headroom band
  ticks every 30s (label yields to a focused curve's tip and a hovered
  nub), hover right of now reads the clock alone. Two toggles, both `auditToggle` icon
  buttons (no room for a third segmented control at 360pt):
  @AppStorage dayDetailStyle ring↔24h-timeline in the drill-down
  (session meter), weekChartStyle bars↔window on 7D (weekly meter,
  page-aware span). Toggles hide when the rank's meter or its
  limitWindow is unknown. Data degrades honestly: percent ≈56d
  (samples), nubs while transcripts live (SessionSummary now carries
  its merged `stretches` — scanner unionIntervals feeds both
  activeSeconds and the nubs), outcomes forever from v0.55.0.

## The horizontal swipe catcher

- HORIZONTAL SWIPE: `HorizontalSwipeCatcher`
  (Panel/) turns a two-finger horizontal trackpad swipe into ONE
  arrow-equivalent step (threshold 55pt, fired once per gesture phase
  cycle, momentum/mouse-wheel events never step). Mechanism is a
  bounds-scoped LOCAL NSEvent monitor, NOT responder-chain views — the
  activity surfaces live inside the panel's vertical ScrollView and a
  .background sibling never sees wheel events, while a hit-testing
  overlay steals clicks/hovers; the monitor claims only gesture-phased,
  horizontal-dominant events inside its view's bounds and passes all
  else through. A LOCAL MONITOR PRECEDES VIEW DISPATCH (v0.87.2 lesson):
  "deeper" scroll views never keep their events from it — an enabled
  catcher over the All grid ate every horizontal gesture while pageStep
  no-opped, killing the grid's scrolling for a week — so the catcher
  carries an `enabled` flag (inert = pass-through, the PanCatcher
  pattern) and the pager attachment disables it on All; any future
  surface that owns a horizontal scroller must do the same.
  scrollingDeltaX honors natural scrolling: fingers
  left = +1 = later. Consumers: 7D/30D pager (`pageStep`) and the day
  drill (`stepDay`) — both extracted so arrows and swipes share one
  action; sign convention: direction < 0 = earlier.
