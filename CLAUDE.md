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
- One refresh pipeline, one entry point: `UsageStore.refresh(reason:)` owns
  single-flighting, the 60-second minimum interval, and 429-backoff
  enforcement for every trigger (timer, wake, network-restore, manual,
  launch, activity).
- Polling cadence is adaptive (`AdaptiveCadence`, pure + tested): quiet time
  decays the user-chosen active interval ×2 (15 min) / ×4 (1 h) / ×8 (4 h),
  capped at an hour between polls — or at the chosen pace itself when that's
  deliberately slower. The pace is a logarithmic slider in settings
  (3 min–2 h, `RefreshIntervalScale`: magnetic marks at the presets, clean
  rounding between them); the panel's ⋯ menu keeps the 3/5/15 quick picks
  plus the current in-between value so its picker never shows empty. Evidence of use snaps it back: FSEvents on
  `~/.claude/projects` (`ClaudeActivityWatcher` — observational only, never
  reads paths) is the push signal for Claude Code; percentages rising between
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
- Color thresholds live in `Thresholds` (≥70 warning, ≥90 critical); an API
  `severity != "normal"` forces at least warning regardless of percent.
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
  the scanners, nothing leaves the machine. The same scan also attributes
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
  prompt volume) doubling as a legend: models wear stable
  rank-assigned `ModelPalette` colors, hovering a row filters the chart to
  that model (heatmap re-ramped against `HeatmapLayout.modelMaxTokens`,
  its busiest own day, so light models keep contrast), the 7D bars are
  per-model stacked with band order fixed period-wide, and clicking any
  day pushes (animated, with a back button) into a per-day drill-down —
  model donut + the same grid scoped to that day. The grid is one shared
  component (`ModelBreakdownGrid`), also the meter popovers' table. The
  popover chart overlays the meter's percent line with EVERY model's
  cumulative token curve (normalized so the busiest model spans the plot);
  one `focusedModel` state drives both the chart (focused curve full
  opacity + area, rest dimmed) and the legend rows — hover either surface
  and both light, since they render from the same binding. A
  Sliding|Window span picker (hidden without a live reset; choice
  persisted per meter via @AppStorage `meterPopoverSpan-<id>`, since the
  shared popover would otherwise leak one meter's choice onto the next)
  switches the X domain between trailing-now and the limit window
  start-to-reset; the
  Window span draws a 30s-ticking vertical now rule and the prediction engine's
  dashed trajectory, and hover readouts right of it report
  "proj. N%" off that curve. When the pace spends the limit before reset,
  a red rule marks the crossing and a Canvas in chartBackground hatches
  the unreachable region diagonally; the crossing's time label shows only
  while hovering the dead zone (always-on it crowded the axis labels) and
  fits inside the plot. All spans carry an iStat-style activity strip: a
  band below the plot floor (chart Y domain extends to −8; AreaMarks pin
  yStart: 0 so fills don't bleed into it) — orange segments where
  transcripts logged tokens, faint track otherwise, scoped meters
  counting only their own model. Idle gaps within the grace period
  (`ActivityGrace.stitch`, default 15 min, Settings → General slider
  down to off) are bridged — the user pausing to read or reply is still
  the same session; the raw runs show only at 0. Hovering below the plot floor hands the
  hover to the strip: the nub brightens, its peers recede, dimming
  curtains (windowBackgroundColor 0.5) cover the graph outside the
  hovered slice — the undimmed slice IS the highlight — and the readout
  line reports the stretch's range and duration; curve focus and point
  readouts stand down there. The dead stretch past the exhaustion
  crossing gets a red nub of its own ("unreachable" in the readout).
  Segmented pickers are built ONLY through the shared `SegmentedPicker`
  (Sources/ClaudeUsage/SegmentedPicker.swift — mini/bare/semibold, one
  place for the style; settings panes pass size: .regular). Hover-driven stats lines are fixed-height by
  design — swapping text must never reflow the layout under the cursor —
  and today's cell/bar carries a subtle ring (grids only — the 7D bar's
  bold weekday label suffices). A Tokens|Cost segmented picker beside the
  period picker re-values every chart surface (cell intensity, bar
  heights/segments/labels, tooltips, stats line, drill ring) via
  `CostIndex` — per-day cost prebuilt next to the layout so render
  passes never price models; unpriced models drop out of cost mode.
- Cost estimates: `PricingTable` (per-token `ModelRates`, exact-id then
  date-stripped lookup) from `PricingService` — disk-cached LiteLLM feed
  refreshed when >24h old (attempted at most hourly, piggybacked on usage
  refreshes), `PricingTable.bundled` as the offline floor. Estimates are
  list-price counterfactuals; subscription plans don't bill per token.
- The settings window (⋯ menu → Settings…, `SettingsWindowController` —
  created on first show, kept alive across closes, explicitly fronted
  because cooperative activation won't front a background app's window)
  navigates with a left sidebar (`NavigationSplitView`, toggle removed):
  a General pane and an API Cost pane — pricing-feed status with a manual
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
  consolidation of the old BurnRate/BurnEstimate pair): rate from persisted
  percent samples (`UsageHistory` in App Support) using the monotonic tail
  after the last drop (limit resets never produce bogus negative rates),
  then a single `UsagePrediction` per meter — rate, projected-at-reset,
  exhaustion date, verdict, caption text, and a chartable trajectory curve
  clamped at 100 with a knee at the crossing. Every surface that talks
  about the future (meter captions, the popover's Window graph) reads it;
  never re-derive projections ad hoc. Verdicts: red = exhausts before
  reset at current rate, yellow = projected ≥85% at reset, green otherwise.

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

- `LSUIElement` in `Support/Info.plist`; no Dock icon.
- Any binary that reads the Keychain must be signed with the stable identity
  via `scripts/sign.sh` BEFORE its first run (default identity
  `Apple Development: Avihu Turzion`, override with `CODESIGN_IDENTITY`).
  Ad-hoc signing changes identity every build and re-triggers Keychain
  prompts — never ship or run an ad-hoc build against the Keychain.
- Keychain query: login keychain, no `kSecUseDataProtectionKeychain`.
- Menu bar rendering: height from `NSStatusBar.system.thickness` (never
  hardcoded), `monospacedDigitSystemFont` so width doesn't jitter,
  `isTemplate = false` (we color by severity).
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
- Work is milestone-gated (spec §12, mirrored in the session task list):
  stop and show the user at each milestone boundary; don't start the next
  without their go.
- Commit only when the user asks, or when structurally required (say so
  explicitly when it is).
- Every commit that bumps `AppIdentity.version` gets a matching annotated
  tag (`vX.Y.Z`) on that commit, pushed alongside it.
