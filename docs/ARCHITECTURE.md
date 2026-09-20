# Architecture

The shape of the system: how the core, the hosts and the faces fit
together, and the rules that bind anything wired into them.

**Read this before** changing how data reaches a face, adding a landing
point to the engine, touching storage layout, or moving code between
targets.

Siblings: [DAEMON.md](DAEMON.md) (the engine's hosts and the digest in
full), [HARNESSES.md](HARNESSES.md) (providers, accounts, identity),
[MEASUREMENT.md](MEASUREMENT.md) (what the numbers mean),
[UI.md](UI.md), [CHARTS.md](CHARTS.md), [CLI.md](CLI.md),
[TUI.md](TUI.md).

## The core / app split

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

## Engine and hosts

The engine (`UsageEngine`), what a host runs (`MeteringHost`), the digest
(`live-state.json`), the control socket and the lease arbitration between
hosts are documented in full in [DAEMON.md](DAEMON.md) — **read that
first.** What follows is only what binds code on the app side of the
seam.

- The app-side `UsageStore` is a thin `@Observable` façade over the
  engine, preserving the historical member surface: Observation tracks
  through its computed forwards into engine storage, which is why views
  and controllers were untouched by the v0.64.0 extraction. Keep that
  forwarding intact — breaking it silently stops views updating rather
  than failing to compile. Its one AppKit piece is the `NSWorkspace`
  didWake observer wired to `noteWake()`.
- `UsageStore` runs one of two modes, `hosting(UsageEngine)` or
  `client(DigestClient)`. `DigestClient` rebuilds digest → core types
  (meters, predictions, plan, spend, typed errors) and reads history,
  ledger, pricing and transcripts READ-ONLY (`scanTranscriptsReadOnly`):
  the lease holder is the sole cache writer, spec §10.
- COLOUR AND RISK MATH IS CORE, not app-side: `RiskRamp`
  (Formatting/RiskRamp.swift — a pinned dark-appearance yellow→red ramp;
  panel `riskColor`, the menu bar and the digest all blend through it) and `ModelColorMath` (pure HSB, slot 0 =
  provider accent). `ModelColorLedger` owns the ONE ledger write path
  (`grow(_:defaults:providerID:)`); the app's `ModelPalette` only maps
  stored slots to SwiftUI `Color`s. A face that computes a colour itself
  will disagree with the other faces.
- Engine/Scheduler.swift is a one-shot Timer plus `NWPathMonitor`;
  Engine/AgentActivityWatcher.swift is FSEvents. Both descended into core
  with the engine — nothing schedules or watches from the app layer.

## The provider seam

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
  Exactly one provider ACTIVE at a time — RETIRED by 0.101.0: the seam now
  carries CONCURRENT metering (see MULTI-HARNESS below), and nothing is
  "the active provider". UsageStore takes it at init and the
  ✳︎/name/links flow from it. App/product branding (app name — "Agent
  Usage" since 0.101.0, `AppIdentity.displayName` — bundle id, repo name, accent orange) is deliberately NOT behind
  the seam — renaming is a product decision, not plumbing. Adding a
  provider later = a new UsageProvider implementation + a spec §10
  amendment for its hosts (and for any local trees it reads); the engine,
  history, charts, and panel need zero changes.

## Refresh: one pipeline, one entry point

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
  rule stopping at 100 IN THE PROVIDER ACCENT, capped by the VENDOR'S MARK
  in the headroom (`HarnessStyle.glyph` = the provider's menuBarGlyph,
  Claude's ✳︎, OpenAI's for Codex — v0.92.1, user-directed: "the vendor did
  this", so the vendor's colour and logo, never a generic ↺ or primary), NO
  curtain (no window closed), readout "Limit reset · ~Thu
  21:10 · from 30%". The dashed
  boundary rule + curtain stay exclusively `.windowEnd`.
  A GRANT IS ONE ACCOUNT-WIDE EVENT (v0.92.3, user-reported: the session
  meter had closed at its own 19:xx boundary and sat at zero when the reset
  landed, so its day drill and 24h History showed nothing while the weekly
  charts did): `VendorGrants.observed(samples:for:through:)` (Audit/) reads
  mid-window cliffs off EVERY OTHER meter's samples, re-voices `from` as
  the chart's own standing percent (readouts omit "from 0%"), dedupes
  within 120s, and `VendorGrants.union(own:foreign:)` — own reading wins
  an instant — feeds both `AuditWindow.build` and the popover's
  `percentSeries`. Whatever any meter saw, every meter marks.
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

- Timers get generous `tolerance`; refresh on `didWakeNotification` and
  network-path restore. Never poll faster than 180s (`TriggerGate.floor`;
  tightened from 60s on 2026-08-13 — the endpoint rate-limits sustained
  sub-3-minute polling, anthropics/claude-code#31637) — adaptive cadence may
  only ever slow polling down from the user's chosen active interval, and
  `RequestLedger` tracks the trailing hour against an estimated budget
  (learned tighter from real 429s) so the panel can warn before manual
  refreshes trip the limiter.

## Decoding and endpoint knowledge

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

## Cross-device sync (designed, not shipped)

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
