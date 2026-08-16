# claude-usage-menubar — agent guidelines

Personal macOS menu bar app (LSUIElement, single user, not for distribution)
showing Claude plan usage limits from the undocumented `/api/oauth/usage`
endpoint, authenticated with the local Claude Code OAuth access token. The
build contract is `docs/SPEC.md` — milestones in §12, acceptance in §13.
Push back on the spec when reality disagrees with it; record corrections in
the README rather than silently deviating.

## Hard rules (spec §10 — non-negotiable, flag rather than work around)

- Never write to the Keychain. Never read or use the refresh token — access
  token only, re-read on every refresh cycle, never cached in memory or disk.
- The token is never logged, persisted, placed in a URL, or included in any
  error surface. Cache response bodies only.
- Exactly two network destinations: `api.anthropic.com` (usage, with the
  OAuth token) and `raw.githubusercontent.com` (LiteLLM pricing feed —
  plain GET, never any credential or account data attached; user-directed
  spec §10 amendment, 2026-08-13, see README). No analytics, no telemetry.
- No App Sandbox. No entitlements we don't need.
- Never install or register anything (login items, launch agents) without
  asking the user in-session. Launch-at-login is a user-clicked toggle only.
- Honest `User-Agent` (`claude-usage-menubar/<version>` via `AppIdentity`);
  never impersonate Claude Code or the Claude app.
- Every failure mode must render readable state. A blank or crashed menu bar
  item is a bug.
- If a permission prompt or tool denial blocks credential-adjacent work,
  surface it to the user (`!` commands) — do not route around it.

## Architecture

- `UsageCore` is a library with zero AppKit/SwiftUI imports; all logic is
  headlessly testable. The app layer is a pure function of store state.
- CODE LAYOUT (2026-08-16 v0.63.0 reorg): UsageCore groups by subject —
  Api/ Refresh/ Credentials/ Providers/{,Claude,Codex,Gemini}/ Activity/
  Sessions/ Pricing/ Prediction/ Audit/ Formatting/ Storage/ Digests/ —
  with AppIdentity.swift alone at the core root (the release-bump sed
  path). App target: App/ MenuBar/ Store/ Components/ Panel/ Charts/
  Sessions/ Settings/. The four big view files split along existing type
  boundaries (UsagePanelView → MeterRow/RiskColor/MeterHistoryView;
  SessionsView → SessionRow/SessionComponents/SessionDetailPane;
  SettingsView → SettingsScaffolding/GeneralSettingsPane/CostSettingsPane;
  TokenFormat, CodexActivitySource, SessionChartModel out of their old
  host files) — byte-identical moves, `private`→`internal` only where a
  type crossed its old file. New code lands in the matching folder; a
  file that outgrows ~600 lines splits along whole-type seams like these.
- ENGINE (2026-08-16 v0.64.0, phase E of the daemon/TUI program): the
  orchestrator is core `UsageEngine` (Engine/UsageEngine.swift, @MainActor
  @Observable public) — refresh gate/backoff, cadence, transcript scans,
  predictions, pricing, and color-ledger seeding all live there. Hosts
  inject their UserDefaults domain (app: `.standard`; usaged will pass the
  app's suite) and forward their platform wake signal to `noteWake()`.
  Engine/Scheduler.swift (one-shot Timer + NWPathMonitor, wake observer
  removed) and Engine/AgentActivityWatcher.swift (FSEvents) descended with
  it. App-side `UsageStore` is a thin @Observable façade preserving the
  historical member surface — Observation tracks through its computed
  forwards into engine storage, so views/controllers are untouched — plus
  the one AppKit piece: the NSWorkspace didWake observer wired to
  noteWake(). ModelColorLedger owns the ONE ledger write path
  (provider-scoped key, `grow(_:defaults:providerID:)`); app ModelPalette
  only maps stored slots → SwiftUI Colors.
- LIVE-STATE DIGEST (2026-08-16 v0.65.0, phase D1): the engine publishes
  its whole renderable state to `<App Support>/com.avihu.ClaudeUsage/
  live-state.json` (bundle root, above provider scopes) after every
  landing point — fetch (the heartbeat), prediction pass, scan, pricing,
  settings — via Engine/StatePublisher.swift (atomic temp+rename, serial
  utility queue). Schema `LiveState` (Digests/LiveState.swift): FROZEN,
  additive-only forever, SyncDigest discipline; absent ≠ zero (unpriced
  cost / unreported percent = null, NEVER 0). Golden fixtures in
  Tests/UsageCoreTests/Fixtures/digest/ are decoded by BOTH
  LiveStateTests and (from v0.67.0) the Rust TUI's serde contract tests —
  regenerate ONLY with `UPDATE_GOLDENS=1 swift test --filter LiveState`
  and read the diff. Consumers render, never compute: pre-phrased
  captions, resolved colors. Color/risk math is core now:
  `RiskRamp` (Formatting/RiskRamp.swift, pinned dark-appearance
  yellow→red, panel riskColor + menu bar + digest all blend through it)
  and `ModelColorMath` (pure HSB, slot 0 = provider accent; app
  ModelPalette wraps it). `usage-cli state` prints the file verbatim.
  docs/DAEMON.md holds the architecture; the §10 amendment is IN FORCE
  from v0.66.0.
- DAEMON + HOST ARBITRATION (2026-08-16 v0.66.0, phase D2): `usaged`
  (Sources/usaged/, 5th target, embedded signed at ClaudeUsage.app/
  Contents/MacOS/usaged) runs the engine headless under launchd
  (com.avihu.usaged: RunAtLoad, KeepAlive, ThrottleInterval 10; IOKit
  wake with sleep acknowledged immediately; daily redetect via shared
  HarnessResolution). Install is USER-RUN ONLY: `usage-cli daemon
  install|uninstall|start|stop|status` / `mise run daemon -- <verb>`.
  THE DAEMON WINS: Engine/EngineLease.swift (flock on engine.lock —
  kernel-released, stale-proof), daemon.alive 2s marker, Engine/
  ControlSocket.swift (NDJSON unix socket 0600, one request per
  connection; commands status/refresh/setInterval/setProvider/
  settingsChanged/refreshPricing/scanNow/shutdown), Engine/
  EngineHostBroker.swift (pure rules: hosting app yields ≤30s of a
  fresh marker; client takes over only when heartbeat outages max(2×
  poll horizon, 3min) AND lease free, gate SEEDED from the digest's
  fetchedAt so handovers never double-poll — a sub-floor takeover
  presents UsageService.cachedSnapshot as live). App side: UsageStore
  façade runs Mode.hosting(UsageEngine)/Mode.client(DigestClient);
  DigestClient rebuilds digest→core types (meters/predictions/plan/
  spend/typed errors) and reads history/ledger/pricing/transcripts
  READ-ONLY (scanTranscriptsReadOnly — lease holder is the sole cache
  writer, spec §10). Verified live: yield 10-14s, takeover ≤35s, no
  double-poll, meters instant from cache. Keychain: usaged shares the
  app's signing identity; its first fetch may prompt ONCE. The app-hosted
  engine ALSO runs the control socket (host trio travels together) — a
  TUI works identically against either host; app-side socket refuses
  setProvider/shutdown (registry owns switching; nobody kills an app
  over a socket).
- RUST TUI (2026-08-16 v0.67.0, phase T1; tui/ cargo crate, usage-tui):
  the dependency rule is SCOPED — UsageCore/app/usaged stay zero-dep
  Swift; the TUI carries exactly ratatui, serde, serde_json, time
  (crossterm comes re-exported through ratatui so versions can't drift),
  Cargo.lock committed, rust pinned in mise [tools] (1.95, daft-style
  minimum_release_age 7d). The TUI is a FACE: reads live-state.json +
  sends socket commands; no network, no credentials, no writes. Digest
  mirrors live in tui/src/digest.rs with #![allow(dead_code)] (mirror
  completeness over usage) and MUST decode the same goldens as
  LiveStateTests — that pair of suites IS the schema freeze from here on
  (additive-only for real now). Layout = dynamic shape math
  (tui/src/layout.rs): strip under 10 rows/40 cols, landscape at
  cols ≥ 2.1×rows, priority flow header→meters→today→models→heatmap→
  footer, sections drop WHOLE. time crate: local offset captured once
  in main() before threads (soundness gate), UTC fallback. Verify
  renders headlessly: tmux new-session -d -x W -y H + capture-pane
  (sizes 100×27, 46×30, 72×16, 46×8).
- PROVIDER SEAM (2026-08-15 v0.25.0, user-directed decoupling): everything
  vendor-specific sits behind `UsageProvider` (Providers/UsageProvider.swift) —
  identity (serviceName/agentName/menuBarGlyph/links/networkDestinations),
  `credentials: CredentialChain`, `fetchRawUsage`, `snapshot(fromRawUsage:)`
  (bytes → normalized `Snapshot`; the cache stores raw bytes and replays
  them through the provider), `makeLocalActivity(cacheDirectory:)` (protocol
  `LocalActivitySource`: watchDirectories/displayPath/scanTranscripts/
  scanPromptDays/diskUsage — read-only by contract), `agentSettings`
  (protocol `AgentSettingsStore`: the ONE sanctioned retention write),
  `modelCatalog` (`ModelCatalog` closures: displayName/familyName/
  familyRank), `bundledRates`. `ClaudeProvider` (Providers/Claude/ClaudeProvider.swift) is
  the only implementation and owns every Claude fact: the OAuth endpoint
  (via UsageClient), keychain/file credential chain, ~/.claude paths
  (ClaudeActivitySource), cleanupPeriodDays (ClaudeCodeSettings
  conformance), claude-id grammar + Fable/Mythos>Opus>Sonnet>Haiku tier
  ladder, claude.ai links, the ✳︎ glyph, the bundled rate table.
  `MeterBuilder` is the Claude adapter proper — the ONE place its limit
  vocabulary ("session"/"weekly_all"/"weekly_scoped") becomes normalized
  meters. NOTHING outside those files may name a vendor: no claude.ai
  URLs, no ~/.claude paths, no "Claude Code" strings (views read
  `store.provider.*`; error text takes `agent:`), no model-id parsing
  (`ModelNames` is a facade over the installed catalog —
  `nonisolated(unsafe)` static written ONLY on MainActor by
  ProviderRegistry while re-binding the active provider, at launch and
  on a Metering switch, always before dependent UI rebuilds; defaults
  to `.claude` as the bundled provider). `Meter` carries what
  used to be rank heuristics as DATA: `limitWindow` (5h/7d),
  `rateWindow` (45min/4h via `defaultRateWindow` tiering ≤6h),
  `forcesWarning` (severity floor — `Snapshot.rebuilt` re-levels meters
  in place, no payload retained), `scopedModelName` (no UI label
  parsing). `PredictionEngine.window(forRank:)`/`windowLength(forRank:)`
  are GONE — predict reads the meter; nil limitWindow = pure-linear.
  Exactly one provider ACTIVE at a time (a seam for adopting other
  agents, not concurrent metering); UsageStore takes it at init and the
  ✳︎/name/links flow from it. App/product branding (app name "Claude
  Usage", bundle id, repo name, accent orange) is deliberately NOT behind
  the seam — renaming is a product decision, not plumbing. Adding a
  provider later = a new UsageProvider implementation + a spec §10
  amendment for its hosts (and for any local trees it reads); the engine,
  history, charts, and panel need zero changes.
- SESSIONS BROWSER (2026-08-15 v0.30.0, user-directed "axis 3"): a
  dedicated Sessions NSWindow (SessionsWindowController — the exact
  SettingsWindowController contract: lazy first-show,
  isReleasedWhenClosed=false, center() THEN setFrameAutosaveName,
  activation trio every show, close() registered in
  StatusItemController.adopt() BEFORE outgoing.shutdown()). Data layer:
  `TranscriptScan.sessions: [SessionSummary]` — per-file summaries ride
  the scanner's cache (v4; ONE `cacheVersion` constant now, never three
  literals) as `SessionFileSummary` (title/firstPrompt≤120-scrubbed/cwd/
  branch/entrypoint/version/start/end/stretches/prompts/toolCalls/
  compactions; apiCalls + models stay DERIVED from `days` — never stored
  twice), merged by path (`/subagents/` substring → part of the `<uuid>`
  before it; covers workflows depth). TRAPS the design review caught,
  now load-bearing: (1) `message.content` is a STRING on user lines —
  `BlockList`'s lenient unkeyed decoder absorbs it; a synthesized
  `[Block]?` silently drops every command/compaction/prompt line via the
  loop's `try?`. (2) Metadata rules run BEFORE the usage keep-rule —
  `ai-title` has no timestamp and would die at the old front guard.
  (3) Tool counting sees every assistant line BEFORE dedup (streamed
  lines share usage but carry DISTINCT tool_use blocks; count a per-file
  id Set). (4) Session active time = sweep-UNION of per-file
  grace-stitched stretches (subagents run concurrently — summing or
  re-stitching double-counts). (5) `queue-operation` records duplicate
  their dequeued user record — ignore entirely. Capability gate:
  `LocalActivitySource.providesSessions` (default false) +
  `sessionDetail(id:)` (default nil) — hides the ⋯ "Sessions…" item and
  window for sessionless providers. Store: `sessions` published in
  scanActivity's MainActor hop (single-flighted via isScanningActivity),
  `sessionDetail(id:)` detached at .userInitiated with cancellation
  propagated (SwiftUI's .task(id:) cancels on selection change — keyed
  by a composite DetailKey{id, end} so live sessions refresh per scan).
  `usage-cli sessions [--provider id]` prints the index via
  `scan(persistCache: false)` — the APP is the cache's sole writer.
  Background runs: `entrypoint != "cli"` → badge + dim + toggle
  (default SHOW, user decision; no parent attribution — verified no
  linkage exists in hook transcripts). `--sessions` launch hatch.
  Spec §10 amendment lists exactly what the cache may materialize.
  RECONCILIATION (v0.32.0, user-reported $630-vs-$610 discrepancy):
  sessionDetail parses the main file AND every `<id>/subagents/**` file
  fresh from disk — NO cache read at all (the ≤60s-stale rollup died
  with it); subagent API calls join the rows time-interleaved, carrying
  `SessionEvent.subagent` (dimmed "· subagent" rows), so the detail
  ledger reaches the card's total EXACTLY. The chart endpoint trailing
  the sidebar by the subagents' spend is a bug class, and
  subagentRollup's rowTokens == summary.totalTokens assertion is its
  regression test. Freshness rides FSEvents → scanActivity (1/min
  throttle) → DetailKey{id, end} re-fires the parse. SKELETON
  (v0.34.0): a selection SWITCH clears stale detail synchronously in
  the .task (the previous session's content must never linger as a
  frozen pane) and shows a skeleton whose header + ModelBreakdownGrid
  are REAL — the sidebar summary already knows them — with pulsing
  bars only for chart + rows (Pulsing honors Reduce Motion); a
  same-id re-fire keeps content and swaps silently, and hover state
  resets only on id change. The skeleton must be width-neutral
  (v0.35.0): SkeletonBar widths are CAPS (maxWidth), never fixed
  frames, and the placeholder rows live inside the same ScrollView
  shell as the loaded list — a skeleton whose minimum width exceeds
  the loaded content's makes the split view widen on every selection
  and snap back when the parse lands. DASHBOARD HEADER (v0.37.0,
  user-approved mock): three bands, all derived from the sidebar
  summary so the skeleton renders the whole header real — (1) title +
  cost KPI top-right (ModelBreakdownGrid's centered headline is
  suppressed via showsHeadline: false; the number appears ONCE), (2)
  icon context strip (FlowLayout of SF-Symbol chips: folder / branch /
  calendar / timer / terminal / number; empty facts omit their chip,
  never "—"), (3) six StatTiles in an HStack of equal maxWidth:
  .infinity shares — the grid must always FILL the header width and
  stretch with resizes (user-directed; that's why it's an HStack, not
  an adaptive LazyVGrid, which wraps 5+1 under squeeze). Tile styling
  (v0.38.0–v0.40.0, user-directed): the WHOLE tile wears a light wash
  of its StatTint (fill 0.1, hover-deepened to 0.16 over 0.12s) under
  a slightly stronger frame (0.3) of the same tint; glyph, value (20pt bold, a touch lighter than
  standard label ink in dark), and label stack CENTERED with the
  glyph on its own row (a corner glyph collided with the centered
  value on narrow tiles); the prompts tile wears the provider
  accent — ❯ is the app's prompt color story. CTX COLUMN (v0.41.0):
  call rows show tally.inputSide over ModelRates.contextTokens (the
  feed's max_input_tokens; bundled mirrors the real feed — 1M for the
  5-family + opus-4-6..8 + sonnet-4-6, 200K legacy, nil where the
  feed has none) between OUTPUT and COST — "<1%" below one percent,
  "—" only when nobody knows the window. THREE traps solved here,
  don't regress them: max_input_tokens decodes as Double (an exotic
  feed value must not knock out the entry's whole pricing row); a
  disk pricing cache from BEFORE the field counts as stale
  (isStale's allSatisfy-nil clause) so the column populates one
  refresh tick after update, not 24h later; and the view falls back
  to the bundled floor's window while that stale cache still serves.
  The skeleton carries the matching bar. ROW COST POPOVERS (v0.43.0):
  call and prompt rows click open (pointerStyle .link; the hover tint
  holds while open, the grid's held-lit idiom). A call row opens
  CostMathView with its own model+tally — IDENTICAL to clicking a
  model row. A prompt row opens the totals-card ModelBreakdownGrid
  scoped to its span (SessionSpanTally in UsageCore: promptRange =
  prompt through the row before the next prompt or session end;
  models/calls clamp stale ranges so a live re-parse can't trap),
  headed by the ❯ preview + "N API calls through the next prompt/the
  session's end"; the grid's model rows keep their own CostMathView
  click-through (nested popover) and its hoveredModel binding is the
  pane's real one, so hovering models in the popover focuses the
  chart behind — popover onDisappear clears it so a dismissal
  mid-hover can't leave the chart stuck focused. Command/compaction
  rows have no cost story and don't open. Fixed popover width (344)
  because a Text's ideal width is its unwrapped width — natural
  sizing would let a long preview blow the popover out.
  PANEL SHORTLIST (v0.45.0): the panel shows a "Sessions" strip
  below the activity heatmap — SessionShortlist.build (UsageCore):
  newest ≤3 INTERACTIVE sessions (background never listed), hasMore
  true when the cap or the background filter hid anything, which
  shows the "Show more…" button (plain onOpenSessions). Rows are the
  sidebar's FULL SessionRow card (v0.47.0 user-directed; SessionRow
  is internal, not private, exactly so both surfaces render one
  component and can't drift; palette = the same all-sessions union
  the window computes, so dots match across surfaces) wrapped in the
  grid's hover/link idiom; clicking calls onOpenSession(id) →
  StatusItemController.showSessions(selecting:) →
  SessionsWindowController.show(selecting:) → SessionsNavigator
  (@Observable, consume-once `requested`) → SessionsView applies it
  in BOTH .onAppear (request set before a fresh window's first
  render) and .onChange (retarget while open), selecting + scrolling
  the sidebar then clearing the request. The section gates on
  store.providesSessions.
  CODEX SESSIONS (v0.31.0): CodexActivitySource populates the same
  seam — one rollout file = one session (cache v2; SessionMeta stores
  title/cwd/cli_version/start/end/stretches, counts derived from
  DayTally), title = scrubbed first user_message, kind always
  .interactive (rollouts carry no headless marker), detail rows from
  user_message + token_count deltas. Gemini stays sessionless.
- MESSAGE-TABLE PERFORMANCE (2026-08-16, v0.61.0–v0.61.2, user: "VERY
  sluggish" scrolling): the table is LAZY, NOT VIRTUALIZED — LazyVStack
  creates rows on demand and RETAINS every one it ever created. The
  v0.61.0/.1 restructure (Equatable MessageRow + one interaction-layer
  overlay with fixed-row-height hit math + one popover proxy) DID NOT
  improve the felt scroll performance (user verdict) and caused three
  regressions (dead cost popover — anchor inserted in the presenting
  transaction; popover anchored at the list top — .offset is a render
  transform AppKit ignores when resolving popover anchors; dark
  slivers between lit rows), so v0.61.2 REVERTED the table wholesale
  to the per-row-modifier form (v0.60.3 state). Do NOT re-attempt that
  restructure. If sluggishness is tackled again, the lever is real
  row recycling: an NSTableView-backed List or NSTableView wrapper,
  not SwiftUI-side diffing. Transferable macOS facts learned: popover
  anchors resolve against LAYOUT frames (position anchors with
  padding, never .offset), and a popover whose anchor view is
  inserted in the same transaction that flips isPresented is silently
  dropped.
  (Panel/) turns a two-finger horizontal trackpad swipe into ONE
  arrow-equivalent step (threshold 55pt, fired once per gesture phase
  cycle, momentum/mouse-wheel events never step). Mechanism is a
  bounds-scoped LOCAL NSEvent monitor, NOT responder-chain views — the
  activity surfaces live inside the panel's vertical ScrollView and a
  .background sibling never sees wheel events, while a hit-testing
  overlay steals clicks/hovers; the monitor claims only gesture-phased,
  horizontal-dominant events inside its view's bounds and passes all
  else through (deeper scroll views like the All grid keep their events
  before it anyway). scrollingDeltaX honors natural scrolling: fingers
  left = +1 = later. Consumers: 7D/30D pager (`pageStep`) and the day
  drill (`stepDay`) — both extracted so arrows and swipes share one
  action; sign convention: direction < 0 = earlier.
  auditable "including seeing if the limit was reached"): `WindowLedger`
  (UsageCore) records each CLOSED limit window's outcome —
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
  fixed-height verdict caption). Two toggles, both `auditToggle` icon
  buttons (no room for a third segmented control at 360pt):
  @AppStorage dayDetailStyle ring↔24h-timeline in the drill-down
  (session meter), weekChartStyle bars↔window on 7D (weekly meter,
  page-aware span). Toggles hide when the rank's meter or its
  limitWindow is unknown. Data degrades honestly: percent ≈56d
  (samples), nubs while transcripts live (SessionSummary now carries
  its merged `stretches` — scanner unionIntervals feeds both
  activeSeconds and the nubs), outcomes forever from v0.55.0.
- SYNC DIGEST (2026-08-16 v0.51.0, axis-1 prep, membership-gated):
  `Digests/SyncDigest.swift` (UsageCore) is the FROZEN CloudKit schema —
  digest types + `SyncDigestBuilder` + `SyncRecordName`, pure, Codable,
  zero CloudKit imports. Design and rationale live in docs/SYNC.md
  (zone-per-device writer-owns-zone merge model, archive semantics,
  encryptedValues-everything, additive-only evolution); the spec §10
  amendment there is a DRAFT, not in force — no transport code exists
  and none ships until the paid Apple Developer membership lands and
  the amendment is signed off. Record names and privacy invariants
  (no full paths, no preview fields, no dollars in encoded bytes) are
  pinned by SyncDigestTests; treat both as one-way doors — production
  CloudKit schemas are additive-only. `usage-cli sync-digest` prints
  this machine's digest (read-only cache use, zero network, no
  Keychain). Dollars never sync: viewers price tallies with their own
  feed.
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
  is provider DATA like the glyph — `UsageProvider.accent:
  ProviderAccent` (pure sRGB components; UsageCore stays UI-framework-
  free): Claude terracotta #D97757, Codex OpenAI-green #10A37F, Gemini
  blue #4285F4. App side: `ProviderStyle` facade (Components/ProviderStyle.swift,
  `nonisolated(unsafe)` statics accent+providerID, installed by
  ProviderRegistry beside ModelNames.catalog — same written-only-on-
  MainActor-before-UI-rebuilds contract). Derived surfaces: menu bar
  glyph tint (StatusItemRenderer.accent — claudeOrange is GONE),
  heatmap ramp + prompt-only wash + strip/ring fallbacks (HeatmapView),
  trajectory/rhythm tints, and `ModelPalette.colors` slot 0. The color
  LEDGER is now provider-scoped ("<id>.modelColorLedger",
  StorageMigration v2 — marker "storageScopeVersion" counts phases) so
  every harness's heaviest family wears its own vendor accent instead
  of another vendor's leftover slot. SEMANTIC colors (warning orange,
  critical red, severity ramp, cached badge) deliberately stay fixed —
  only brand accents follow the harness.
- GEMINI PROVIDER (2026-08-15 v0.28.0, thin and honest): `GeminiProvider`
  (UsageCore/Providers/Gemini/GeminiProvider.swift) — local-files-only like Codex, but
  Google serves NO readable usage numbers, so the one meter (rank 0,
  "Daily · counted locally", limitWindow 24h, reset next midnight
  America/Los_Angeles) is a LOCAL count of today's prompts vs an assumed
  cap: UserDefaults "gemini.dailyRequestCap" (default 1000 free /
  1500 AI Pro / 2000 Ultra), surfaced via the NEW generic
  `UsageProvider.preferences: [ProviderPreference]` (protocol-extension
  default []; Settings renders a stepper card per preference and nudges
  a manual refresh on change — the seam rule holds, no vendor names in
  the app layer). Traces: `~/.gemini/tmp/<hash>/logs.json` (decode ONLY
  timestamp+type — message text never materialized, spec §10 amendment)
  + `chats/session-*.jsonl` headers; session days stand in only where
  the log has no entries (never double-count). No token data exists →
  scanTranscripts returns empty and prompt days paint the faint
  heatmap cells; fetchedAt = count time (a zero count is FRESH info —
  unlike Codex this meter is never stale). `PricingFeedSelector` gained
  `normalizeKey` (gemini feed keys are "gemini/"-route-prefixed;
  stripped so transcript ids match). SlidingFrame default tier: ≤6h →
  .h5, ≤24h → .h24, else .d7. oauth_creds.json/google_accounts.json
  never read.
- CODEX PROVIDER (2026-08-15 v0.27.0, first non-Claude harness):
  `CodexProvider` (UsageCore/Providers/Codex/CodexProvider.swift) is LOCAL-FILES-ONLY —
  zero network destinations, zero credentials (`StaticCredentialSource`
  returns an empty token so UsageService stays byte-identical;
  `~/.codex/auth.json` is NEVER read, spec §10 amendment). Meters come
  from the newest `token_count` event's `rate_limits` in
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (primary=session 300min,
  secondary=weekly 10080min, used_percent + resets_at epoch-seconds;
  walk newest-first past local-model sessions whose limits are empty;
  ALL fields optional — the schema drifted between Feb/May 2026 CLIs).
  Aging rule: resets_at < now ⇒ the window rolled ⇒ 0% and no reset
  shown. `Snapshot.fetchedAt` = the event's own timestamp, and the
  status line's stamp is day-aware (`UsageFormatting.updatedStamp`) so
  stale local data reads honestly. Activity: `CodexActivitySource` maps
  `last_token_usage` deltas + the active `turn_context.model` →
  TokenSlots/DailyActivity (input = input−cached, cacheRead = cached,
  output includes reasoning, cacheCreation 0 — OpenAI bills no
  cache-write class; `total = input+output` arithmetic-verified);
  per-file mtime/size parse cache, version 1, in the provider's scoped
  dir. LOCAL-PROVIDER GATING: `networkDestinations.isEmpty` ⇒ no
  RequestLedger recording, no API gauge, no budget lockout, manual
  refresh bypasses the TriggerGate (a disk rescan needs no rationing).
  New `noLocalData` case on BOTH UsageClientError and UsageError ("No
  local <agent> sessions found yet") — without it a sessionless local
  provider rendered as "Network unavailable". Pricing: providers declare
  a `PricingFeedSelector` slice of the LiteLLM feed (claude=anthropic,
  codex=bare openai keys); codex ships an EMPTY bundled table (live feed
  or "—", never stale hardcoded guesses). `scopedTag` now reads
  `scopedModelName` as data (the last label-parsing claude-ism).
- MULTI-PROVIDER REGISTRY (2026-08-15 v0.26.0): `ProviderRegistry`
  (app layer) is now the one place a vendor is chosen — it lists every
  bundled provider (Claude only so far), detects the actively-used
  harness, and owns the ACTIVE provider's UsageStore; switching retires
  the old store. Detection = `HarnessDetector` (UsageCore): scores
  SESSION-ARTIFACT mtimes only under each provider's watchDirectories
  (count modified ≤14d, tie-break newest, walk capped at 2000 stats) —
  never state/config mtimes, which background daemons touch for months
  after real use stops. Resolution: UserDefaults "activeProviderID"
  ("auto" default) > detection > bundled-first order; `--provider <id>`
  launch hatch forces one run without persisting; daily auto re-detect
  defers its switch until the panel closes. Metering pickers live in the
  panel ⋯ menu (hidden while only one harness is present) and Settings →
  General (with per-harness signal rows). Storage is PROVIDER-SCOPED via
  `StorageScope` (UsageCore): all four artifacts (usage.json,
  history.json, activity-cache.json, pricing.json) live under
  `<base>/<bundleID>/<providerID>/`, vendor-fact defaults keys are
  prefixed (`claude.apiHourlyCeiling`), and the two per-meter popover
  @AppStorage keys carry the provider id — accounts later = one more
  path component in StorageScope, nowhere else. Meter labels key
  history/predictions INSIDE those files, which is only safe because no
  two providers share a directory. `StorageMigration` (one-time,
  copy-verify-delete, marker "storageScopeVersion", runs FIRST in
  applicationDidFinishLaunching) moved the pre-0.26 singletons into
  claude/. Switch teardown lessons: UsageStore.shutdown() (engine shutdown
  stops the Scheduler's NWPathMonitor + the FSEvents watcher, and the
  façade releases its didWake observer — all leak without it),
  SettingsWindowController.close() before dropping it (never
  dealloc a visible NSWindow), and observeState()'s re-arm carries a
  store-identity guard (a stale observation landing post-switch would
  otherwise double-register tracking).
- One refresh pipeline, one entry point: `UsageEngine.refresh(_:)` (the
  UsageStore façade forwards to it) owns single-flighting, the 60-second
  minimum interval, and 429-backoff enforcement for every trigger (timer,
  wake, network-restore, manual, launch, activity).
- Polling cadence is adaptive (`AdaptiveCadence`, pure + tested): quiet time
  decays the user-chosen active interval ×2 (15 min) / ×4 (1 h) / ×8 (4 h),
  capped at an hour between polls — or at the chosen pace itself when that's
  deliberately slower. The pace is a logarithmic slider in settings
  (3 min–2 h, `RefreshIntervalScale`: magnetic marks at the presets, clean
  rounding between them); the panel's ⋯ menu keeps the 3/5/15 quick picks
  plus the current in-between value so its picker never shows empty. Evidence of use snaps it back: FSEvents on
  the provider's watch directories (`AgentActivityWatcher` — observational
  only, never reads paths) is the push signal for the agent; percentages rising between
  polls (`UsageMovement` — rises and fresh-window usage count, drops are
  resets) is the pull signal that catches Claude app/web use. A push signal
  also polls immediately when the shown data is older than the active
  interval (`shouldPollOnActivity`) — keyed on data staleness, not the decay
  multiplier, because agent sessions keep evidence warm while the user is
  away, and stale-keyed polls also recover timers App Nap let drift. HTTP 429 maps
  to `.rateLimited(retryAfter:)` and starts exponential backoff (5 min
  doubling to 1 h, `Retry-After` honored up to 2 h) that heals on the next
  success; automatic triggers sit backoff out, manual refresh may punch
  through. The scheduler timer is one-shot — every completed refresh (and
  every denied trigger) must leave a live timer behind.
- `UsageClient` makes exactly one attempt and maps to typed errors. The
  retry (once, transport errors only, ~2s delay) lives in the store.
- Decode defensively: every field optional, unknown limit kinds render
  generically, unparseable dates degrade to nil — schema drift must never
  crash. The `limits` array is canonical; the legacy top-level buckets
  (`five_hour`, `seven_day`) are deliberately not modeled.
- Dates go through `FlexibleISO8601`: the live API sends six fractional
  digits + numeric offset (`.137024+00:00`), which both stock
  `ISO8601DateFormatter` variants reject.
- Color thresholds live in `Thresholds` (defaults ≥70 warning, ≥90
  critical — user-adjustable in Settings → Thresholds, persisted in
  UserDefaults, min 5 points apart); an API `severity != "normal"` forces
  at least warning regardless of percent. `Snapshot` retains its decoded
  response so `store.thresholdsChanged()` re-classifies the live snapshot
  the moment a slider moves.
- Endpoint knowledge stays in `UsageClient` + `UsageModels` so migrating to
  a supported endpoint, if one ships, is a one-file change.
- The activity heatmap reads Claude Code's local transcripts
  (`~/.claude/projects/**/*.jsonl`) via `TranscriptScanner` — strictly
  read-only, dedup by requestId, mtime/size cache in this app's own App
  Support dir — merged (`ActivityMerge`) with prompt timestamps from
  `~/.claude/history.jsonl` via `PromptHistoryScanner` (epoch-ms, no token
  counts, survives Claude Code's `cleanupPeriodDays` sweep): days with
  prompts but no surviving transcripts render faint as "no token data".
  Never write inside `~/.claude`, never go near `.credentials.json` from
  the scanners, nothing leaves the machine — with ONE user-authorized
  exception (2026-08-14): the Settings → General transcript-retention
  control writes exactly `cleanupPeriodDays` in `~/.claude/settings.json`
  through `ClaudeCodeSettings` (read-modify-write preserving every other
  key, atomic, refuses to touch a file whose content doesn't parse).
  Nothing else ever writes there. The same scan also attributes
  tokens per model (`TokenTally`: in/out/cache-write incl. the 1h-TTL
  split/cache-read): per day forever (`DailyActivity.models`, feeding the
  per-period summary via `HeatmapLayout.modelTotals`) and per minute for a
  trailing 8 days (`TokenSlot` timeline, cache-bounded — feeds the
  per-meter window breakdowns via `WindowTokens`). Day tooltips stay a
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
  (percentPerToken = the window's percent gain / its total tokens) so
  the models' combined spend meets the percent growth exactly and no
  token curve towers over the usage that contains it (fallback:
  busiest-model spans the plot, only when percent data is missing/flat);
  one `focusedModel` state drives both the chart (focused curve full
  opacity + area, rest dimmed) and the legend rows — hover either surface
  and both light, since they render from the same binding. While focused,
  the Y axis re-labels its same gridlines as tokens (percent ÷
  percentPerToken) at one fixed label width — the mode flip must never
  resize the plot — and the model's name rides above its curve tip in
  its color. Chart labels are LAYERED: strip duration > focused-model name >
  now — lower layers disappear while an upper one overlaps
  (nowEclipsed's track-space estimate). A
  Sliding|Window span picker (hidden without a live reset; choice
  persisted per meter via @AppStorage `meterPopoverSpan-<id>`, since the
  shared popover would otherwise leak one meter's choice onto the next)
  switches the X domain between trailing-now and the limit window
  start-to-reset; the
  Window span draws a 30s-ticking vertical now rule (labeled with the
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
- Cost estimates: `PricingTable` (per-token `ModelRates`, exact-id then
  date-stripped lookup) from `PricingService` — disk-cached LiteLLM feed
  refreshed when >24h old (attempted at most hourly, piggybacked on usage
  refreshes), `PricingTable.bundled` as the offline floor. Estimates are
  list-price counterfactuals; subscription plans don't bill per token.
- The settings window (⋯ menu → Settings…, `SettingsWindowController` —
  created on first show, kept alive across closes, explicitly fronted
  because cooperative activation won't front a background app's window)
  navigates with a left sidebar (`NavigationSplitView`, toggle removed):
  General, Usage, and API Cost panes. The Usage pane
  (UsageSettingsView.swift) surfaces the forecast engine's working —
  per-meter recent rate, baseline + basis, pace factor, projection,
  hysteresis state — plus the learned weekly-rhythm grid (7×6 heat cells,
  claude-orange intensity) with busiest/quietest-day insights, sample-
  history stats (count, span, thinning, on-disk size), and a plain-words
  explainer; card scaffolding (`SettingsCard`/`SettingsPaneScroll`/
  `infoRow`/`note`) is shared internal from Settings/SettingsScaffolding.swift. The API
  Cost pane — pricing-feed status with a manual
  Refresh Now (`PricingService.refreshNow` — bypasses the daily staleness
  gate, same single allowed destination), the list rates behind the
  estimates, a Claude Code-specific cost explainer, and a what-if
  playground over `CostSimulator` (UsageCore, closed-form: writes =
  C+(n−1)g, reads = (n−1)C+g(n−1)(n−2)/2 — cache reads grow quadratically
  with session length, which is the explainer's core lesson). Panes are
  hand-rolled cards in a ScrollView, NOT `Form(.grouped)`: grouped forms
  column-align bare controls (the refresh slider got squeezed into the
  trailing half-column while its mark labels spanned the row) and
  mis-measure wrapped text in custom rows (the token-class grid overlapped
  its neighbors). The panel's ⋯ menu and the General pane share
  `SettingsBindings` so both surfaces stay in lockstep. `ClaudeUsage
  --settings` opens the window at launch and `--panel` opens the main
  panel — the verification hatches, since menus and the status item can't
  be scripted (`mise run axdump` / `mise run axpress` — the harness's eyes
  and hands — dump frames and press controls for layout checks; both
  default to the newest running ClaudeUsage). Popover windows never
  appear in AXWindows (both tools sweep the app element's roleless
  children to catch them), and any real user click dismisses the panel —
  don't AX-verify it while the user is mousing.
- Plan identity: `CredentialsParser` also surfaces `subscriptionType` /
  `rateLimitTier` (`PlanInfo` — metadata beside the token, never the
  refresh token); it rides `Snapshot.plan` and renders under the panel
  title.
- Predictions are one engine (`PredictionEngine` in UsageCore — the
  consolidation of the old BurnRate/BurnEstimate pair): the recent rate is
  a least-squares slope over persisted percent samples (`UsageHistory` in
  App Support), fit to the monotonic tail after the last drop (limit
  resets never produce bogus negative rates; the fit — not an endpoint
  secant — keeps one integer-quantized step from spiking it), measured
  over 45 min for the session meter and 4 h for weeklies. DAMPED BLEND
  (2026-08-15, v0.24.0): for windows ≥1 day the projection is NOT linear —
  the recent rate's excess over a baseline decays with `burstDecayHours`
  (τ = 1 h, closed form τ(1−e^(−h/τ))), so a hot session charges the
  forecast about one hour of itself while the baseline carries the rest of
  the horizon; the session meter deliberately stays pure-linear
  (`minimumWindowForBaseline` — at 5 h scale the burst IS the signal and
  damping would under-warn). The baseline is the learned `WeeklyProfile`
  once ≥14 days of history exist (42 buckets = 7 weekdays × 4-hour blocks,
  local time, Sunday-absolute indexing; consumption between sample pairs
  attributed uniformly across spanned blocks; pairs skipped on percent
  drop, moved reset, or gaps >48 h; bucket rates shrunk toward the global
  mean by `priorHours` = 8 of pseudo-observation; scaled at predict time
  by a pace factor (actual+5)/(expected+5) clamped 0.25–4), else the
  window's own average pace (percent ÷ elapsed, needs ≥30 min). Each
  `UsagePrediction` carries rate, baseline rate, pace factor, `basis`
  (recentOnly/windowAverage/weeklyProfile), projected-at-reset, exhaustion
  date (bisected on the curved trajectory), verdict + `rawVerdict`
  (two-refresh hysteresis: the displayed verdict flips only when two
  consecutive raw readings agree — `previous` prediction feeds forward
  through UsageStore), continuous `severity` (0 at the 85% projection,
  ramping to 1 at the limit), caption text, and a chartable curve (48
  samples, bends from burst slope to baseline slope, clamped at 100 with a
  knee). Profiles + predictions rebuild per refresh OFF-MAIN
  (`recomputePredictions` detached task). `UsageHistory` retains 56 days:
  the recent 7 at full poll resolution, older thinned to one sample per
  15 min (first-per-bucket, stable as samples age across the boundary).
  Every surface that talks about the future reads the one engine; never
  re-derive projections ad hoc. Verdicts: red = crossing before reset,
  yellow = projected ≥85% at reset, green otherwise. PRESENTATION (2026-08-14):
  on-track forecasts are silent — no caption; a predicted crossing
  appends "runs out in 1h 05m" / "runs out Sat 14:00"
  (`UsageFormatting.exhaustText`, sharing resetText's `eventPhrase`
  tiers) to the reset line. Risk rides color, not text: meter bars and
  menu bar segment numbers blend yellow→red by `severity` (accent/white
  while clean; percent-threshold palette only when no prediction
  exists — no hard warning/critical cliff). The blend lives in ONE
  file-scope `riskColor(severity:)` (Panel/RiskColor.swift) — bars,
  captions, the chart's dashed trajectory and its Y-axis projection
  label all call it. The Window chart labels the
  projected finish percent on the Y axis in that ramp color
  (only while finishing within limits; a standard mark it would eclipse
  is dropped, `axisLabelClearance` 12 domain units ≈ one label height);
  percent-mode Y labels carry a % sign.

## Swift practices

- Swift 6 strict concurrency: types `Sendable`, UI state `@MainActor`,
  `@Observable` for the store. No `@unchecked` without a comment proving why.
- Zero third-party dependencies — Foundation/AppKit/SwiftUI only.
- SPM package, no `.xcodeproj`. The app bundle is assembled by script;
  everything in the repo is reviewable text.
- Explicit `CodingKeys` per type; don't mix in `convertFromSnakeCase`.
- Protocol seams for testability (`CredentialSource`), value types elsewhere.
- Deployment target macOS 15.

## macOS app practices

- `LSUIElement` in `Support/Info.plist` sets the LAUNCH state: no Dock icon,
  no Cmd+Tab. DockPresence (v0.44.0) overrides it at runtime: while any
  hosted window (Sessions, Settings) is open the app is a `.regular` app
  (Dock tile, Cmd+Tab, SwiftUI's default main menu), dropping back to
  `.accessory` when the last closes. One process-wide holder keyed by
  visible-window identity — per-window flips would yank the Dock tile when
  one of two open windows closes. It takes each hosted window's DELEGATE
  seat (free today; if a window ever needs its own delegate, DockPresence
  must move to willClose notifications). Window controllers call
  `DockPresence.shared.adopt(window)` on every show, BEFORE `NSApp
  .activate()` so the menu bar rides along.
- Any binary that reads the Keychain must be signed with the stable identity
  via `scripts/sign.sh` BEFORE its first run (default identity
  `Apple Development: Avihu Turzion`, override with `CODESIGN_IDENTITY`).
  Ad-hoc signing changes identity every build and re-triggers Keychain
  prompts — never ship or run an ad-hoc build against the Keychain.
- Keychain query: login keychain, no `kSecUseDataProtectionKeychain`.
- Menu bar rendering: height from `NSStatusBar.system.thickness` (never
  hardcoded), `monospacedDigitSystemFont` so width doesn't jitter,
  `isTemplate = false`. Since v0.21.0 the title is a DRAWN NSImage
  (`StatusItemRenderer.image`), not attributedTitle: digits stay white —
  thin glyph strokes can't carry color legibly over Liquid Glass (HIG:
  color rides fills, not fine features) — and exhaustion risk arrives as
  solid geometry instead: a ramp-colored dot ahead of a watched number
  (severity 0→0.75), escalating to a filled red capsule carrying the
  segment's tag + digits in bold white at severity ≥ 0.75 (or discrete
  critical). Stale stays grey and ornament-free.
- The status item is a raw `NSStatusItem` owned by `StatusItemController` —
  NOT `MenuBarExtra`. The menu bar's appearance follows wallpaper tinting,
  not the app's appearance; MenuBarExtra rasterizes its label in the app's
  appearance and produced dark-on-dark text. Setting `button.image` lets
  AppKit draw inside the button's appearance context, where dynamic colors
  resolve correctly; KVO on `button.effectiveAppearance` re-renders on
  theme/tint changes. The panel is SwiftUI in an `NSPopover`.
- `.transient` alone cannot dismiss the panel popover: in an LSUIElement app
  under cooperative activation (macOS 14+) the app usually never becomes
  active, so clicking elsewhere produces no deactivation to close on. While
  the panel is shown, a global mouse-down/scroll monitor plus a
  `didResignActiveNotification` observer close it (torn down in
  `popoverDidClose`); global monitors never see in-panel events, so any hit
  means the user went elsewhere. The same inactivity means the panel window
  is never key on its own — and a non-key window consumes the first click
  to focus itself, so SwiftUI tap targets needed two clicks (NSControl
  pickers mask this via `acceptsFirstMouse`). `makeKey()` right after
  `popover.show` fixes it; keep it if the show path ever moves.
- Timers get generous `tolerance`; refresh on `didWakeNotification` and
  network-path restore. Never poll faster than 180s (`TriggerGate.floor`;
  tightened from 60s on 2026-08-13 — the endpoint rate-limits sustained
  sub-3-minute polling, anthropics/claude-code#31637) — adaptive cadence may
  only ever slow polling down from the user's chosen active interval, and
  `RequestLedger` tracks the trailing hour against an estimated budget
  (learned tighter from real 429s) so the panel can warn before manual
  refreshes trip the limiter.

## Testing

- Fixtures live in `Tests/UsageCoreTests/Fixtures/`, loaded via
  `Bundle.module` (subdirectory `"Fixtures"`). Real captured payloads are
  named `real-YYYY-MM-DD.json` — capture a fresh one via `mise run cli` when
  the schema drifts. Never put a real token or account identifier in a
  fixture; usage percentages and dates are fine.
- Every decode/builder behavior has a fixture test; malformed and unknown
  input must degrade gracefully, and tests prove it.
- Network behavior is tested with a `URLProtocol` stub — tests never hit the
  live endpoint.
- The credential path is NOT unit-tested; verify it live with `mise run cli`.
  Fixtures prove the renderer, not credential access — exercise the real
  path before calling a milestone done (spec §11).
- `swift test` green before showing any milestone.

## Workflow

- daft-managed, contained layout: bare `.git/` at repo root, worktrees as
  siblings (`main/`). New branches via `daft start <branch>` — never
  `git worktree add`, `git checkout -b`, or in-place branch switching.
  Moving/renaming worktrees invalidates `.build` (absolute paths in the
  module cache) — `rm -rf .build` and rebuild.
- Every app/dev-lifecycle script must be runnable as a mise task — when a
  script lands in `scripts/`, a `mise.toml` task wrapping it lands in the
  same change (`mise tasks` is the catalog).
- Day-to-day: `mise run test` / `mise run cli` / `mise run build` /
  `mise run app` (rebundle + relaunch) / `mise run bundle` (no launch)
  from the worktree.
- The app icon (the "cursor fuel" mark — mint prompt chevron, block cursor
  charged yellow→orange to the budget left) has NO checked-in asset:
  `scripts/icon.swift` draws it in CoreGraphics (512-pt design space mapped
  onto Apple's 824-pt grid; ≤32 px renders simplify — heavier chevron, no
  baseline). `scripts/icon.sh` (`mise run icon`) caches the `.icns` at
  `.build/icon/AppIcon.icns`, regenerating only when the renderer changes;
  `bundle.sh`/`dist.sh` copy it into `Contents/Resources` and
  `CFBundleIconFile` points at it. Changing the mark = editing the renderer.
- Work is milestone-gated (spec §12, mirrored in the session task list):
  stop and show the user at each milestone boundary; don't start the next
  without their go.
- Commit only when the user asks, or when structurally required (say so
  explicitly when it is).
- Every commit that bumps `AppIdentity.version` gets a matching annotated
  tag (`vX.Y.Z`) on that commit, pushed alongside it.
