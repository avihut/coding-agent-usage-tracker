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
- UNDER NO CIRCUMSTANCES may a feature require the user to enter system
  credentials — Keychain consent, admin authorization, TCC prompts — for the
  app's REGULAR operation (user-directed §10 amendment 2026-08-25). The
  v0.82.1 promptless credential path (`/usr/bin/security`, see the Keychain
  bullet in macOS practices) is the standing mechanism; never replace it
  with a native read. A very specific dedicated feature MAY be an
  exception, but only with its own well-reasoned, documented §10 amendment
  spelling out why no promptless path exists.
- The token is never logged, persisted, placed in a URL, or included in any
  error surface. Cache response bodies only.
- Four network destinations, and no others: `api.anthropic.com` (usage, with
  the OAuth token), `raw.githubusercontent.com` (LiteLLM pricing feed — plain
  GET, never any credential or account data attached; user-directed spec §10
  amendment, 2026-08-13, see README), the active provider's declared
  status feed (`status.claude.com` for Claude; §10 amendment 2026-08-19,
  v0.86.0 — anonymous conditional GET, ephemeral cookie-less session), and
  this app's own release feed (`api.github.com` releases/latest, §10
  amendment 2026-08-23, v0.87.0 — anonymous conditional GET every 6h, for
  any install whose distribution channel declares a feed: both GitHub
  flavors since v0.88.0; the release asset from `github.com`/
  `objects.githubusercontent.com` downloads exclusively on a user click).
  No analytics, no telemetry.
- A status feed is declared by `UsageProvider.statusFeed`, NOT added to
  `networkDestinations`: that list being empty is what makes a provider
  "local" (`isLocalProvider` — no budget gauge, refresh = rescan), so folding
  a status host in would silently reclassify Codex/Gemini the day they get
  feeds. The privacy card renders it on its own line.
- The account-identity source is declared by `UsageProvider.accountIdentity`
  (§10 amendment 2026-08-25, v0.89.0): a LOCAL read-only file read — for
  Claude, one key of `~/.claude.json` — never a credential store, never a
  network request, never attached to anything transported. Zero network
  destinations added; the privacy card renders the path on its own line.
- No App Sandbox. No entitlements we don't need.
- Never install or register anything (login items, launch agents) without
  asking the user in-session. Launch-at-login is a user-clicked toggle only.
  ONE standing exception (user-directed 2026-08-16, v0.70.0): the
  com.avihu.usaged launch agent auto-installs from the UI entry points via
  core LaunchAgentInstaller, governed by the sticky `daemonAutoInstall`
  opt-out (uninstall paths set it false; every auto-install honors it).
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
  HarnessResolution). Install is AUTOMATIC since v0.70.0 (spec §10
  re-amendment): core Engine/LaunchAgentInstaller.swift converges the
  agent (install absent → repoint moved → bootstrap unloaded → kickstart
  stale-version daemon, decision table `ensureAction` unit-tested); the
  app runs `ensure` at every UsageStore init (detached, Bundle-relative
  binary), the TUI spawns `usaged ensure` once when EngineOffline, and
  usaged doubles as its own installer (`usaged install|ensure|uninstall`,
  plist → argv[0]). Sticky opt-out `daemonAutoInstall`: uninstall verbs +
  the Settings "Background metering engine" toggle set false, install/
  toggle-on re-arm. CLI faces stay: `usage-cli daemon
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
  double-poll, meters instant from cache. Keychain reads are promptless
  through /usr/bin/security since v0.82.1 (see Keychain bullet). The app-hosted
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
- SESSIONS RENAME + SEARCH/SORT (2026-08-17): titles are click-to-rename
  in the sidebar cards AND the detail header (SessionRow's affordance is
  OPT-IN via handlers — the panel shortlist passes none, its rows are
  click-to-open; Escape cancels BEFORE the focus-loss commit, which the
  owners drop as stale). Custom names are an app-side OVERLAY:
  `SessionRenames` (core, tested) persists `session-renames.json` in the
  app's provider support dir (§10-clean; orphans kept — pruning against a
  partial scan could drop live renames), applied in `UsageStore.sessions`
  so every app surface agrees; the DIGEST keeps derived titles (TUI/CLI
  parity for custom names is a deliberate follow-up). Empty or
  derived-equal commit clears the override; detail header reads
  `customSessionName ?? parse title` so live re-parses can't wash a
  rename away. Sidebar search+sort: `SessionOrdering` (core, tested) —
  match over title/path/branch/id; axes recency/name/tokens/cost
  (@AppStorage keys `sessionsSortKey`/`sessionsSortAscending`, FROZEN),
  ties break newest-first, absent cost (unpriced-only, the "—" cards)
  sinks to the END in BOTH directions, day sections exist ONLY on the
  recency axis (`SessionDayGroup.build` needs newest-first input;
  ascending reverses groups + members), navigator requests clear the
  query so a landing can't be hidden by a stale filter. v0.83.0
  refinements (user-directed): a rename click parks the caret on the
  CLICKED character, never AppKit's select-all — `FieldEditorCursor`
  maps the tap (window coords off NSApp.currentEvent) through the field
  editor's characterIndexForInsertion, bounded retries, end-of-text
  fallback; renameable titles wear the id-chip grammar (hover tint +
  `.pointerStyle(.link)`); the card's top-right KPI presents the ACTIVE
  SORT's value — the tokens sort promotes the token total there and
  demotes cost to the caption line (`SessionRow.sortKey`; the shortlist
  passes none → cost default), name/recency keep cost since their values
  already own fixed prominent homes.
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
- CLI QUERY SURFACE (2026-08-17 v0.81.0): `usage-cli <noun> [selector]
  [field] [flags]` — Digests/DigestQuery{,Format,Nouns}.swift (UsageCore,
  pure; the CLI target does file IO + exit only). 13 digest-backed nouns
  (status limits limit budget spend activity cost models model sessions
  session prompt get) answered from live-state.json ONLY; three registers
  (human / --raw bare+TSV / --json via LiveState.encoder()); absent ≠
  zero ON STDOUT ('—' / empty / null, never $0); exit codes are API:
  0 ok (an absent VALUE is still 0), 13 no digest, 19 bad query,
  20 selector matched nothing, 21 stale under --max-age. Range math runs
  in the digest's OWN activity.timeZone — pinned by a Pacific/Kiritimati
  (UTC+14) fixture so a Calendar.current regression fails on ANY host.
  `get` walks the RAW JSON bytes, never the typed structs, so a field
  added to the digest tomorrow resolves today; meters[<sel>] shares
  limit's selector. Singular no-field summaries honor the registers like
  the plurals (entity object / its one list row; non-entity --raw guides
  to a field, exit 19). ROUTING: CLI modes are argv[1] ONLY — a flag
  VALUE spelled "state" must never hijack — and everything else past
  argv[0] goes to DigestQuery, so an unknown noun exits 19 and NEVER
  falls through to the credentialed bare fetch (which survives only as
  the zero-argument debug invocation). That routing gate lives in the
  executable target where no unit test reaches — re-verify live after
  touching main(). Numbers: every
  float on stdout routes through JSONEncoder — NSNumber.stringValue and
  JSONSerialization are NOT shortest-round-trip on Darwin (0.069 →
  "0.06900000000000001").
- USAGE-CLI M2 DEEP VERBS (2026-08-17, v0.83.0): four nouns that read
  PAST the digest — `windows <meter> [hit-rate]` (window-ledger.json,
  newest-first; hit-rate = reachedLimit share, absent over zero windows),
  `history <meter>` (history.json label-keyed samples; TSV t⇥percent in
  BOTH text registers), `prices`/`price <model> [field]` (pricing cache;
  $/MTok = rate×1e6; answers with NO digest via the bundled floor) — plus
  scan-backed `sessions --all` (the SAME shortlist columns, `end` among
  them since 0.84.0; human leads with it) and `session …` deep fields
  (kind/tool-calls/subagents/compactions/agent-version/models — `end`
  left this group in 0.84.0), reachable via a shortlist miss OR
  `session <id> --all`, the escape hatch that scans past a shortlist HIT
  (without it the ≤8 most-recent sessions could never answer a deep
  field); a deep name on a shortlist hit is exit 19 "isn't in the
  shortlist", worded APART from "has no field" on purpose. Dispatcher: DeepQuery.run
  (Digests/DeepQuery.swift); sessions/session route via
  DeepQuerySessionsCLI with the scan injected as a closure
  (buildIndex = persistCache:false, §10). Exit 11 = non-claude provider,
  ahead of every verb body. GRAMMAR: one shared parser with PER-NOUN
  APPLICABILITY — `DigestQuery.rejectInapplicableFlags` returns an M2
  flag on a non-owner noun to exit 19 "unknown flag" exactly as pre-M2
  (the M1 suite does NOT pin this itself; DeepQueryFlagsTests does — keep
  it in mind when touching the shared flag sets). `--last` is
  integer-count-or-duration (disjoint grammars, `DeepQuery.parseLast`) on
  windows/history alike; `--since` is duration-or-yyyy-MM-dd
  (`resolveSinceCutoff`, digest-calendar midnight) on
  windows/history/sessions alike; `--background`/`--no-background`
  REQUIRE `--all` (the shortlist doesn't know kind — refuse, never hand
  back excluded rows). Deep verbs tolerate a nil digest (meter selectors
  degrade to exact ledger/sample matching; worst/next need a digest).
  windows human = the SAME five columns as raw (end start last peak hit;
  a real `false` reads "miss" — the em-dash stays ABSENT-only). Built by
  a 14-agent sonnet+opus workflow (wf_a6974ae9-76f); its verify barrier's
  10 findings were closed by hand before release.
- CLI CONSUMER ERGONOMICS (2026-08-17, v0.84.0): six fixes from an
  outside consumer's review of the shipped query surface — read it as
  the standing contract for anything new here.
  (1) SessionCard.end SHIPS IN THE DIGEST (`Date?`, appended last in
  `sessionColumns`): the shortlist already sorted by it and then threw it
  away, so every liveness check either scanned transcripts per sample or
  invented a proxy. Optional ONLY for backward tolerance — a
  non-optional makes a 0.83-written live-state.json fail to decode
  WHOLESALE, blanking every noun until usaged republishes. Same rule for
  `LiveState.sessionsCap`, stamped by the WRITER like `schemaVersion`:
  `status sessions-cap` reports what truncated THAT list, and stays
  absent for an older digest — never this build's own constant.
  (2) `--no-scan` forbids the shortlist-miss escalation (a ~10ms read
  silently becoming a ~140ms transcript walk); it contradicts `--all`
  (19), and with no digest at all is 13, not 20. `session <id> source`
  says which path answered (digest|scan).
  (3) `--fields a,b,c` on `DigestQuery.multiFieldNouns` (status limit
  budget spend activity model session + M2's price) — one TSV row in the
  text registers, `--header` names the columns, `--json` an object in the
  REQUESTED order (the one deliberate departure from sortedKeys). A
  positional field AND `--fields` is 19; a failing cell fails the whole
  row (never a partial one). Registered per-noun in `flagOwners`, so
  `sessions --fields` is still "unknown flag" — and `windows` is
  catalogued but EXCLUDED (one field has nothing to combine with, and an
  accepted-but-inert flag is the defect class M2's verify barrier caught
  twice).
  (4) `--relative` on a SECONDS field prints `UsageFormatting.duration`,
  mirroring the pre-phrased-caption rule for dates (`--json` unaffected,
  negatives keep their sign); the `session` human summary line carries
  its active duration. Money and tokens were already pre-formatted;
  durations were the inconsistency.
  (5) `DigestQueryFormat.sanitizeCell` at the tsv()/table() JOIN: a cell
  can never contain the separator. Titles were safe only by luck
  (`SessionMeta.scrub` collapses \s+); project/branch never pass through
  it and a macOS directory name may legally hold a tab.
  (6) Field errors ENUMERATE, M2 verbs included (price, windows):
  `DigestQuery.fieldCatalog` (name → scalar|table, in
  Digests/DigestQueryFields.swift) backs both the "— fields: …" list and
  `--fields` validation, so a table-shaped name is refused BY NAME rather
  than by sniffing output. The catalog can drift from the switches, so
  every noun's names are WALKED: DigestQueryFieldsTests for the digest
  nouns (and it asserts the catalog has no key without a walk), price's
  in DeepQueryPricesTests, windows' in DeepQueryWindowsTests — the two
  M2 verbs need injected fixtures the digest suite has no seam for.
  Sessions nouns now live in Digests/DigestQuerySessions.swift
  (DigestQueryNouns.swift had passed the ~600-line split rule).
- HOW A CALL IS COUNTED (2026-08-17, v0.85.0): measured against ccusage
  20.0.20 over the real 2,239-transcript corpus, our cost ran 7.4% LOW.
  The pricing arithmetic was never the problem — same rates, same 1h-TTL
  split, reproducing their per-day cost to the cent given the same tokens
  — all three causes were ingestion, in `parseFile`. These are the rules
  now; do not "simplify" any of them back.
  (1) A STREAMED CALL COUNTS ONCE, AT ITS FINISHED SIZE. Claude Code
  writes one call as SEVERAL lines sharing a request id, each restating
  usage known so far (output_tokens climbing 4,4,4,4,739). Keeping the
  FIRST lost 18.8M output tokens, 31% of the corpus's output. The winner
  is the LARGEST record — sidechain rank decided BEFORE size — which is
  why aggregation now waits for the end of the file instead of running
  inline: days, slots, activeMinutes and the session's reach all take the
  winner's own record and its own timestamp (a group straddling local
  midnight buckets where it FINISHED). Rows still open at the group's
  first line, and still accumulate every line's tool_use blocks — those
  genuinely differ per line, the usage does not.
  (2) `usage.iterations[]` IS PARSED. An `advisor_message` entry is a
  separate API call to a separate model, ADDITIVE to the turn that
  spawned it (proof: corpus input was 4.0M against 75.3M of advisor
  input). Each counts as its own call under the parent's dedup key
  suffixed `:advisor:<i>`, so the sibling lines that each restate the
  whole array collapse. A `message` iteration is the turn restating
  ITSELF — counting it would double the turn. This moves `messages` →
  `SessionSummary.apiCalls` → the `api-calls` field: a session's call
  count now includes its advisor calls.
  (3) ONE CALL BELONGS TO ONE FILE, corpus-wide. A subagent transcript
  opens with the parent turn that spawned it and a resumed session copies
  its history forward, so 352 of 58,861 request ids appear in more than
  one file; per-file dedup billed them twice. `FileEntry` now carries the
  COMPLETE list of calls it holds (`encodeCalls`: 24 hex per call — an
  FNV-1a hash of the dedup key plus a rank packing token total and
  sidechain flag) plus the fingerprint of the exclusion set its
  aggregates were built under. Never narrow that list by exclusion —
  ownership must stay recomputable from cached entries alone, which is
  what lets a file that owns everything fingerprint to 0 and never
  reparse. FNV-1a, never `Hasher`: these are persisted and compared
  across processes. `sessionDetail` dedups WITHIN the session group only
  (main claims its calls, then each part reads excluding what is already
  claimed) — deliberately not the global rule, since it parses fresh and
  has no corpus to consult. That covers the 297 main↔subagent groups;
  the residual is the ~55 sibling-session groups, where a call owned by
  another session's file is excluded from this session's CARD but still
  drawn in its DETAIL view.
  Cache version 6 — every figure persisted under v5 undercounts.
  A COLD CACHE CAN STAMPEDE — hit during this rollout, and the mechanism
  is confirmed, not guessed. A cold scan of this corpus is ~41s (warm:
  0.2s). An empty digest means an empty sessions shortlist, so every
  `usage-cli session <id> <field>` MISSES and escalates through
  `DeepQuerySessions.swift`'s `TranscriptScanner(...).scan(persistCache:
  false)` — a FULL corpus scan that banks nothing. The statusline runs
  exactly that per render, so the misses pile up and starve the daemon
  whose scan would have ended them. (The v0.84.0 "~140ms miss" figure is
  a WARM miss; cold it is the whole 41s.) This fires on a cacheVersion
  bump AND on first install — any empty-digest window. Warm the cache
  with ONE lease-holding scan, then start usaged; `--no-scan` is the
  per-caller guard for anything polling on a timer. The call list also
  grew the cache 2.1MB -> 3.6MB.
  KNOWN, DELIBERATE 0.087% ABOVE ccusage: 1,510 lines state a
  `cache_creation_input_tokens` larger than their own 5m+1h breakdown; we
  bill the vendor's total, they bill the breakdown and drop the rest.
  NOT implemented and inert today: long-context (>200K) tiered rates —
  `ModelRates` has no `*_above_200k` and `PricingFeedClient.decode` drops
  those keys, so if the feed ever carries them for a model in use we
  under-bill silently. Same for a `speed: "fast"` multiplier (every
  entry in this corpus is `"standard"`).
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
  stripped so transcript ids match). HistoryFrame default tier: ≤6h →
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
- RESET STAMPS JITTER (v0.86.1): the API restates `resets_at` with
  sub-second noise on every poll — a fortnight of weekly stamps held no two
  byte-equal values (±0.5s around the true boundary). Every "did the window
  roll?" comparison goes through `ResetStamp`
  (Refresh/ResetStamp.swift, 60s tolerance; real rolls move stamps by
  hours), NEVER Date equality: exact equality starved `WeeklyProfile` of
  92% of its pairs (flat typical-week overlay, flat forecast baseline,
  wrong pace factor) and made `UsageMovement` read every poll as activity
  (quiet-time cadence decay never engaged). Consumers: WeeklyProfile.build,
  UsageMovement.advanced, ResetCliffs.isReset, WindowLedger.closedWindows.
  The raw jittered stamps stay in history.json untouched — they're what the
  API said — so the fix heals retroactively on the first rebuild.
- MID-WINDOW RESETS + STAMP CARRY (2026-09-05 v0.92.0, user-reported):
  Anthropic's 2026-09-04 limit reset zeroed the weekly meters two days
  before their boundary, and until the next spend the API OMITTED
  `resets_at` outright; when usage resumed the SAME stamp came back — the
  window never ended. Two rules now, both core-tested:
  (1) `ResetCarry` (Refresh/): a meter reporting no stamp inherits the last
  observed stamp for its label WHILE THAT STAMP IS STILL AHEAD OF NOW. Safe
  by construction — a future stamp names a window that hasn't ended, and a
  later different stamp is caught by `ResetStamp.moved` as before; a 5h
  session that ended idle carries nothing (stamp in the past). Applied at
  READ time only: the engine fills the fetched state (`carryingResets`, live
  and cache-served alike) so the popover's Current span, the forecast, the
  digest's reset and every face keep the window; history.json still records
  the API's own word (`history.append(asReported)`), and the two chart
  series builders fill the sample series (`ResetCarry.fill(samples)`) so the
  gap already on disk heals. Before this the popover was FORCED onto History
  for the 16 hours the stamp was missing.
  (2) `ResetCliffs.Cliff.kind`: `.windowEnd` (stamp moved) vs `.midWindow`
  (fell to ZERO under an unmoved stamp — any other in-window decrease stays
  a correction, never a cliff). Mid-window cliffs sit at the gap's midpoint
  (no boundary to snap to; the readout says "~"). They flow as their own
  lists — `PercentSeries.midWindow`, `AuditWindowModel.midWindowResets` —
  and draw through `WindowPlot.midWindowResets`: a fine dotted primary
  rule stopping at 100 with a ↺ glyph in the headroom, NO curtain (no window
  closed), readout "Limit reset · ~Thu 21:10 · from 30%". The dashed
  boundary rule + curtain stay exclusively `.windowEnd`.
  `ExhaustedStretches.build(grants:)` ends a lockout at the grant and never
  reaches back across one. The window ledger records nothing for a grant
  (the window didn't close; its later close keeps the pre-grant peak from
  samples). FOLLOW-UP, user-directed for the NEXT version: Anthropic's
  once-a-week user-initiated 5h SESSION reset — mark it on the session
  history AND on the weekly chart ("was it used this week, and when"); the
  detection rule there is "emptied while the OLD stamp still lay ahead"
  (the new window's stamp moves, so the unmoved-stamp rule above won't see
  it), a session drop coinciding with a weekly mid-window drop is the
  vendor's grant, not the user's reset, and the weekly popover needs the
  session meter passed in.
- `UsageClient` makes exactly one attempt and maps to typed errors. The
  retry (once, transport errors only, ~2s delay) lives in the store.
- Decode defensively: every field optional, unknown limit kinds render
  generically, unparseable dates degrade to nil — schema drift must never
  crash. The `limits` array is canonical; the legacy top-level buckets
  (`five_hour`, `seven_day`) are deliberately not modeled.
- Dates go through `FlexibleISO8601`: the live API sends six fractional
  digits + numeric offset (`.137024+00:00`), which both stock
  `ISO8601DateFormatter` variants reject. IT IS A HOT PATH (v0.91.0): the
  scanner calls it once per transcript line, and the old body built three
  formatters per call — a corpus re-parse in the daemon spent 100% of its
  samples inside ICU's TimeZoneFormat allocation and ran for 10+ minutes
  before being killed. Now a hand-rolled integer fast path (days-from-
  civil) parses the canonical shapes; the formatters are built once and
  only see strings outside that grammar. Equivalence and a 20k-parse
  speed floor are pinned in FlexibleISO8601Tests. The full-corpus
  re-parse measured 165s after the fix (2,508 files, this Mac).
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
  trailing 56 DAYS (`TokenSlot` timeline, `TranscriptScanner
  .timelineRetention`, matched to UsageHistory's sample retention since
  v0.91.0 so every window the popover can page back to has its model
  curves; 8 days before that). The cache trims slots to the bound every
  pass and stamps each entry with the cutoff it trimmed to (`FileEntry
  .slotsFrom`); a hit whose stamp sits after today's cutoff with calls in
  between re-parses ONCE despite matching mtime/size (`slotsTrimmed`) — a
  finished transcript never changes, so nothing else could ever backfill
  a longer retention. Growing the retention again is a one-constant change
  plus a one-time corpus re-parse in the daemon, NOT a cacheVersion bump
  (and its stampede). Feeds the per-meter window breakdowns via
  `WindowTokens`. Day tooltips stay a
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
  label all call it. The Current-span chart labels the
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
- KEYCHAIN READS GO THROUGH `/usr/bin/security` (v0.82.1):
  `KeychainCredentialSource` spawns `find-generic-password -w` instead of
  calling `SecItemCopyMatching`. Claude Code writes the item with that same
  Apple tool and REWRITES it on every token refresh, resetting the item's
  ACL grants — so native reads re-prompted per refresh no matter how stable
  our signing (the pre-v0.82.1 "constantly asks for permission" report).
  Reading as the item's own client is permanently silent. Never reintroduce
  a native SecItem read of Claude Code's item; the secret stays pipe→memory,
  never argv/logs (spec §10 unchanged: read-only, access token only).
- Binaries are signed via `scripts/sign.sh` BEFORE first run with a
  MACHINE-LOCAL identity — NO developer account is named anywhere in the
  repo (2026-09-03; a second contributor's clone failed on the old
  hardcoded certificate). Resolution: `CODESIGN_IDENTITY` (per-checkout via
  git-ignored `mise.local.toml`, example file committed) > keychain
  auto-discovery (Developer ID Application > Apple Development > Mac
  Developer) > ad-hoc with a warning. `mise run identity` shows the
  resolution. Ad-hoc is acceptable for a dev build (the Keychain read
  needs no stable signature since v0.82.1) but `dist.sh` sets
  `CODESIGN_REQUIRE_IDENTITY=1` and refuses it — never ship an ad-hoc
  build. Never reintroduce a hardcoded identity, name, or team ID.
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

## Service status (v0.86.0)

- The engine polls the active provider's public status page and publishes a
  normalized `LiveState.serviceStatus` card; every face renders that card and
  polls nothing. `UsageCore/Status/` holds the three pieces: `StatuspageFeed`
  (one endpoint, `/api/v2/summary.json`, conditional GET), `StatusCadence`
  (pure state machine), `StatusPoller` (timer, ETag, resolved-memory).
- Cadence, measured not guessed — CloudFront serves the feed with
  `max-age=10`, so nothing below that can return new bytes: **300s healthy /
  60s while an incident is open / 120s for ten minutes after it resolves /
  60→900s doubling when the feed itself fails**, ±10% jitter. Out-of-band
  pokes (wake, panel open on a card older than 90s, `refreshStatus` over the
  control socket) all pass through the same 10s floor.
- **Absent is not healthy.** A nil card means "nothing tracks status here",
  and every surface must render nothing rather than a green dot. Likewise a
  fetch failure never becomes an incident: three consecutive misses reach the
  grey `unknown` indicator, which is quiet, and `health ok` goes ABSENT
  rather than true.
- Loudness (decision D2): any unresolved incident — minor included — badges
  the menu bar glyph and shows the banners. Maintenance stays quiet: blue
  footer dot and a popover row, never a badge.
- Surfaces: footer dot + hover-pinned popover (`ServiceStatusViews.swift`),
  the provider glyph on an incident-colored capsule
  (`StatusItemRenderer.glyphBadge`), a panel banner above the meters, the
  same banner atop the menu-bar hover popover, and the TUI's four-rung
  ladder (`ui.rs status_rungs`: footer cell → footer text → banner row →
  banner + message; `layout.rs plan_with_status` yields the banner rather
  than the meters).
- `usage-cli health` is the scriptable face — `--check` exits **22** while
  something is open. Named `health` because `status` already answers about
  the engine.
- Verify the UI with `--fake-status <none|minor|major|critical|maintenance|
  unknown|resolved>`: a real outage can't be scheduled, and the hatch carries
  the real 2026-08-18 incident's copy.

## Self-update & distribution channels (v0.87.0, channels v0.88.0)

- Distribution is GitHub Releases; `mise run publish` builds the dist zip
  (universal, timestamped signatures, usaged + usage-cli embedded) and
  attaches it to the version's tag via `gh release create`, notes from the
  tag annotation. Info.plist versions are STAMPED from AppIdentity.swift by
  bundle.sh/dist.sh — never hand-edit them (they drifted two releases behind
  when hand-maintained, and the updater verifies downloads by that key).
- DISTRIBUTION CHANNELS (v0.88.0, user-directed "think of it as
  distribution streams"): every install auto-resolves to a channel
  (`Distribution.channel`, UsageCore/Update/DistributionChannel.swift) that
  owns its whole update story — feed URL, whether one-click install may
  run, and the manual hint when it may not. Today's one channel is
  `GitHubChannel` with two flavors off `InstallKind`'s ancestor walk:
  `.releaseInstall` (standalone bundle, full pipeline) and
  `.sourceCheckout(root:)` (`mise run app` build — polls the SAME feed but
  only informs: pull-and-rebuild hint, never the swap). All the ugly
  install forensics stay inside the channel + `SourceCheckoutProbe`
  (LOCAL-ONLY `git rev-parse` — branch, short sha, is-the-tag-pulled;
  NEVER networked git, which would spend user credentials outside §10's
  destinations). A future store channel returns nil `updateFeedURL` and
  every update surface goes dark. Presentation follows
  `store.updateCanSelfInstall`; `AppUpdater.install` carries the same
  guard as a belt (`Distribution.allowsSelfInstall`), and the drill's
  `updateFeedURL` override forces install-mode through both — the drill's
  staged bundle sits inside the checkout by construction.
- The engine's `UpdateChecker` (UsageCore/Update/) polls
  `api.github.com/repos/avihut/coding-agent-usage-tracker/releases/latest`
  every 6h (conditional GET, honest UA — GitHub refuses UA-less requests)
  and publishes `LiveState.appUpdate`. It runs whenever the install's
  channel declares a feed — both GitHub flavors, so the dev worktree now
  shows the card too (as manual guidance). A failed check keeps the last
  card; only a definitive 404 withdraws it. `AppVersion` compares dotted
  ints; unparseable is NEVER newer.
- UI is deliberately a whisper: an accent `arrow.down.circle.fill` beside
  the footer's version label, an "Update to X…" ⋯-menu item, and a
  Settings → General card (install / Check Now / auto-check toggle / skip
  version via `updateSkippedVersion`; a Distribution identity row names
  the channel + checkout coordinates). On a non-installing flavor the
  arrow and menu item open Settings instead, where the card carries the
  pull-and-rebuild hint (sharpened to "just rebuild" when the release tag
  is already local). No menu-bar change, no notifications. A face whose
  own version already equals the card's stays quiet — the daemon lags one
  relaunch behind right after an update.
- One click runs `AppUpdater` (App/AppUpdater.swift): download (host
  allowlist github.com/*.githubusercontent.com), `ditto -xk`, `codesign
  --verify --deep --strict`, plist version must MATCH the clicked release,
  stage beside the bundle (same volume), two-rename swap with rollback,
  `launchctl kickstart` the daemon, detached-shell relaunch. Downloads by
  the app carry no quarantine (no LSFileQuarantineEnabled), so Gatekeeper
  doesn't re-interrogate updates.
- Verify UI with `--fake-update <version|current>` (no asset URL — a click
  on the fake opens the releases page, never swaps) plus
  `--fake-channel <release|source>` to force the OTHER flavor's
  presentation on whichever flavor the machine actually is. Drill the real
  pipeline against a localhost feed via the `updateFeedURL` defaults
  override, which forces both the checker and install-mode on in a source
  build.

## Account presence & attribution (v0.89.0)

- Every engine landing point (start, wake, scan pass, fetch) observes "who
  is signed in" through the provider's `accountIdentity` seam — for Claude,
  ONE key (`oauthAccount`) of `~/.claude.json`, strictly read-only (spec
  §10 amendment 2026-08-25). Identity compares by the
  accountUuid+organizationUuid PAIR (quotas attach to the org); tier/email
  edits are not boundaries. NEVER the Keychain: the credentials item
  carries no identity, rewrites per token refresh, and any new read there
  risks the v0.82.1 consent-prompt regression. Codex/Gemini declare no
  source; their credential files stay never-read.
- `AccountPresenceLedger` coalesces observations into epochs in the scoped
  `account-presence.json` (atomic rewrite like history.json; a transition
  persists immediately, heartbeats at most every 5 min plus shutdown
  flush; 15s observation floor collapses start+wake+scan pileups). An
  OBSERVED sign-out/switch sets `closedAt` and forbids rejoin; a host that
  merely stopped observing rejoins the same identity, because the gap
  attributes to it either way.
- Attribution is a pure function of timestamp (`AccountTimeline
  .attribute`): inside an epoch exact; an unobserved gap owned only when
  both edges agree; differing edges ambiguous FOREVER; before the first
  observation unattributed FOREVER — absent ≠ zero, history is never
  backfilled by assumption. The join lives entirely in the digest builder
  over the minute timeline the scan already produces: the scanner and its
  cache never learn about accounts (no cacheVersion bump), and minute
  slots bound attribution error the same way they bound window-edge error.
- Digest (additive, Optional): `LiveState.accountPresence` — current ref,
  since/observedAt/attributionSince, `distinctAccounts`, current-first
  today+window rollups per account, reserved `ambiguous`/`unattributed`
  buckets (nil = no such usage), epochs table (newest 50) — plus
  `SessionCard.accounts` chronological labels (nil = writer doesn't
  attribute, [] = attribution ran and named nobody; nil ≠ empty). Labels
  resolve ONCE in the builder: email, org suffix only on collision
  (`disambiguatedLabels`); clients never re-derive them.
- Surfaces auto-show on `distinctAccounts >= 2` and single-account
  machines look exactly as before: the panel status row splits into the D9
  two-line block (top Updated / email at caption·secondary, bottom
  next-in · API / plan at caption2·tertiary, two baseline-aligned
  full-width HStacks — never side-by-side VStacks), session rows carry
  "personal → work" labels (hosting: engine's live timeline; client: a
  label-level timeline rebuilt from the digest's epoch table), and
  Settings About gains the Account row plus the "Account identity —
  ~/.claude.json (read-only)" privacy line and never-sent-anywhere note.
- `usage-cli account`: human summary ("work@example.com · Work Inc · for
  1 hr · today $4.21"), 15 scalars, `accounts`/`epochs` tables (reserved
  buckets as their own rows), `--fields`/`--json`; absent card → empty +
  exit 0, never "no account". Registered in `nouns`, `fieldCatalog`, and
  the fields-walk's `nounPrefix`.
- Verify multi-account UI with `--fake-accounts` (a synthetic
  personal→work switch an hour ago) — the auto-show gate can't be
  produced on demand on a one-account machine.
- Deliberately deferred (ledger): TUI/statusline rendering of the labels,
  heatmap-by-account, an explicit user-initiated "claim history" backfill.

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
- RELEASE RITUAL — a shipped feature or fix is NOT done until it is
  released, in the same session (a fresh session on 2026-09-03 committed
  two changes and stopped, because nothing had written this down; every
  install stayed behind). Minor bump for features, patch for fixes:
  (1) bump `AppIdentity.version` — the ONE version source, Info.plist is
  stamped from it; (2) commit `release: vX.Y.Z` whose body summarizes
  what shipped since the last release (docs that ride along may join it);
  (3) `git tag -a vX.Y.Z` on that commit — the annotation IS the GitHub
  release notes (publish.sh reads it; tags and commits GPG-sign by
  config); (4) `git push origin main vX.Y.Z`; (5) `mise run publish` —
  universal dist zip, timestamped signature from a real identity, attached
  to the tag's release; installed apps see it on their next 6h check.
