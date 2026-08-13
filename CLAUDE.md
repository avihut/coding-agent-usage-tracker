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
  capped at an hour between polls. Evidence of use snaps it back: FSEvents on
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
  input/output/cost columns) doubling as a legend: models wear stable
  rank-assigned `ModelPalette` colors, hovering a row filters the chart to
  that model (heatmap re-ramped against `HeatmapLayout.modelMaxTokens`,
  its busiest own day, so light models keep contrast), the 7D bars are
  per-model stacked with band order fixed period-wide, and clicking any
  day pushes (animated, with a back button) into a per-day drill-down —
  model donut + the same grid scoped to that day.
- Cost estimates: `PricingTable` (per-token `ModelRates`, exact-id then
  date-stripped lookup) from `PricingService` — disk-cached LiteLLM feed
  refreshed when >24h old (attempted at most hourly, piggybacked on usage
  refreshes), `PricingTable.bundled` as the offline floor. Estimates are
  list-price counterfactuals; subscription plans don't bill per token.
- Plan identity: `CredentialsParser` also surfaces `subscriptionType` /
  `rateLimitTier` (`PlanInfo` — metadata beside the token, never the
  refresh token); it rides `Snapshot.plan` and renders under the panel
  title.
- Burn estimates come from persisted percent samples (`UsageHistory` in App
  Support) using the monotonic tail after the last drop, so limit resets
  never produce bogus negative rates. Verdicts: red = exhausts before
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
  means the user went elsewhere.
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
- Day-to-day: `mise run test` / `mise run cli` / `mise run build` from the
  worktree.
- Work is milestone-gated (spec §12, mirrored in the session task list):
  stop and show the user at each milestone boundary; don't start the next
  without their go.
- Commit only when the user asks, or when structurally required (say so
  explicitly when it is).
