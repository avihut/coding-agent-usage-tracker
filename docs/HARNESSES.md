# Harnesses and accounts

Every coding agent on this Mac is metered at once. This doc holds how a
harness is identified, keyed, stored and focused, plus what each shipped
provider actually does.

**Read this before** adding a provider, touching anything keyed by an
account or a harness, or changing focus, storage scopes or identity.

The extension point itself — `UsageProvider` and what may name a vendor —
is in [ARCHITECTURE.md](ARCHITECTURE.md#the-provider-seam). Adding a
provider also needs a spec §10 amendment for its hosts and local trees.

## Multi-account metering (v0.96.0)

- MULTI-ACCOUNT METERING (2026-09-06 v0.96.0, user-directed "meter my
  personal account beside the work one"; §10 amendment in force): several
  Claude Code CONFIG HOMES are metered side by side, one `Profile` each
  (Profiles/ — "Account" in every UI string; `ProfileID.derive` = SHA-256
  of the home path, first 8 hex — Claude Code's own rule, and ALSO its
  Keychain item suffix, so id and credential name can't drift).
  `ClaudeHome` (Providers/Claude/) owns every per-home path and the
  keychain service, and `ClaudeProvider(home:)` is a provider per home; the
  DEFAULT provider stays byte-for-byte what it was (pinned by test).
  Profiles persist as ONE JSON blob in the app's defaults
  (`meteringProfiles` + `focusedProfilePin`) — the channel the daemon
  already reads, not a new §10 artifact. Storage v3 =
  `<bundle>/<provider>/<profile>/` with `scopeKey` = today's key for
  `default` and `<provider>.<id>` otherwise, so a one-account Mac's files
  AND defaults keys are unchanged; the migration takes a BLOCKING flock
  (app and daemon start in the same second after an update).
  HOST: `MeteringHost` (Engine/) is what a host runs — lease, socket,
  publisher, network monitor, one `ProviderServices` per provider (status
  poller, pricing, notice ledger, update checker: everything a single home
  doesn't own) and one `UsageEngine` per enabled home, launches staggered
  by the gate floor. usaged and the app's `ProviderRegistry` both drive it;
  the registry now does the arbitration `UsageStore.init` used to, and
  `UsageStore` is a per-home façade. FOCUS (D9 AS BUILT, superseding the
  design artifact's last-write rule): the most session files over the
  trailing 14 days (`MTimeProbe`, `HarnessDetector.window`), newest write
  breaks ties, pin wins, switch held while the panel is open. DORMANCY
  stays last-write at 30 days — engine stopped, an `AgentActivityWatcher`
  kept to revive it. DIGEST: still ONE file; `focusedProfile`/`profiles[]`/
  `menuBarCells[]` are additive and the focused section is PROJECTED onto
  the top level (`LiveState.viewing(profile:)`), which is why every
  pre-0.96 consumer and every CLI noun answers per account with no per-noun
  code. CLI precedence: `--account <id|nickname|label|home>` >
  `$CLAUDE_CONFIG_DIR` > focused > default; an unknown selector is exit 20
  listing the accounts, NEVER a fallback to another one (a statusline under
  one config dir must never report the other's limits); `accounts` noun;
  deep verbs root their scan at the selected home. UI: ONE renderer whose
  `compose` returns the old single-cell runs for a lone UNLABELED EXPANDED
  cell — that guard is why the one-account bar is byte-identical, and
  `cmp` against the `--snapshot` PNGs is its regression test;
  `AccountStrip` (rows/chips/stacked) is the panel's selector. GUARANTEE
  for this phase: every enrolled profile shares ONE provider, so the
  `ProviderStyle`/`ModelNames` statics stay valid untouched — RETIRED by
  0.101.0, which meters every harness at once (see MULTI-HARNESS below).
  Hatches:
  `--fake-profiles` (a synthetic second account); `--snapshot` also writes
  a PNG per form/arrangement + a hit-rect sidecar + `strip.png`. VERIFY
  GOTCHA: `mise run axdump` no longer sees NSPopover content on this macOS
  (the panel DOES open — verified by logging `popover.isShown`), so panel
  work is checked with `--snapshot` PNGs; `strip-chips.png` comes out an
  ImageRenderer placeholder (NSControl-backed picker). TUI parity deferred
  (v0.98.0): it mirrors the new digest fields and draws neither.

## Multi-harness metering (v0.101.0)

- MULTI-HARNESS METERING (2026-09-20 v0.101.0, user-directed: "how I
  actually want multi harness support to look is like multi-account support
  looks at the moment […] presented alongside each other with an option to
  focus on a different one each time, and polled and tracked
  simultaneously"; §10 amendment 2026-09-20 in force): EVERY harness found
  on this Mac is metered at once. There is no active provider, no Metering
  picker, no `activeProviderID`, and no switch — a harness the person isn't
  interested in is HIDDEN (`hiddenHarnesses` default, read on
  `settingsChanged`), which stops it being DISPLAYED and nothing else: it
  keeps being polled, forecast, priced, and listed under API Cost → Rates
  (user-decided: "No—keep all detected harnesses in the Rates list").
  IDENTITY: every harness's standard account is called `default`, so the
  wire uses a FLAT KEY (`ProfileKey` — the bare id for the bundled provider,
  `StorageScope.scopePrefix` otherwise: `codex`, `codex.ab12cd34`). A
  Claude-only Mac keeps every id it had. Storage is UNCHANGED
  (`<bundle>/<provider>/<profile>/`) and a key NEVER names a directory —
  `ProfileView.accountID` and `gateSeeds()` carry the storage id beside the
  key. The bug class to remember: a face that asks the digest for section
  `default` gets the BUNDLED harness's, so every lookup keyed by an account
  (stores, focus, labels, `DigestClient(profileID:)`) takes `.key`, and only
  paths take `.id`. HOST: `MeteringHost(providers:)` runs one
  `ProviderServices` per harness (`ProviderServicesRegistry` — creating one
  starts a status poller, so only host reconciliation may create; readers
  use `services(forHarness:)`), one `UsageEngine` per enrolled account, a
  pure `HarnessRoster` (present × stored × hidden → rows, two floors: a Mac
  with nothing found still meters the bundled harness, and the last shown
  harness can't be hidden), and `HarnessPresence` (stat only — a provider's
  local source is CONSTRUCTED to ask where it would read, never run —
  latched for the process, re-probed every 10 min so a harness installed
  mid-session joins without a restart). FOCUS is two levels: the harness by
  ACTIVE DAYS in the 14-day window (file counts aren't comparable across
  vendors — Claude's subagents write hundreds), sticky on a tie, then the
  account by today's `FocusRule`; a pin wins. DIGEST, additive only:
  `harnesses[]` (identity, shown/present, activity, account count, and that
  vendor's OWN status/notices/outages), `ProfileState.accountID`,
  `MenuBarCell.accent`, `pinnedProfile`; `viewing(profile:)` projects the
  VIEWED harness's vendor cards, so a dormant Codex account never reads as
  Claude. Second golden `live-state-v1-harnesses.json`, decoded by Swift AND
  Rust — that pair is the freeze. NOTICES are routed, not re-keyed: each
  harness keeps its ledger in storage-id terms and the DIGEST qualifies a
  foreign id (`NoticeRouting`: `codex:reset|…`), so a dismissal splits the
  name and lands in one ledger with no migration. Faces list every SHOWN
  harness's notices (`LiveState.pendingNotices()`, `registry.pendingNotices`)
  because "Dismiss all" spans them; `health --check` asks
  `LiveState.anyIncident()` — about the machine, not the focused harness.
  MENU BAR: `StatusItemRenderer.Model.groups` — one block per harness with
  its own glyph, accent, incident and indicator; the invariance guard reads
  the GROUP's cells (two harnesses with one account each must draw two
  marks), and `glyph`/`cells`/`incident`/`indicator` stay forwards to the
  first group so every pre-0.101 caller and snapshot case was untouched. Hit
  regions carry the harness beside the cell: a click or hover on a mark
  answers for THAT harness's focused account. The shared `NSStatusItem` is
  never removed, only hidden (`isVisible`) — with groups, "every cell took
  its own item" is easy to reach and re-creating that item is the v0.97.2
  blank-bar regression. STYLE: `ProviderStyle` is GONE; `HarnessStyle` is a
  value (accent as core `RGBColor`, never `NSColor` — the renderer's `Model`
  is Equatable and the controller skips redraws on equality), explicit into
  anything hoisted out of its section (the meter popover, the hover card)
  and through `\.harnessStyle` inside a one-account window. `ModelNames
  .catalog` is a constant UNION (`ModelCatalog.union(of:)`, dispatching on
  `claims`/`claimsFamily`, bundled provider FIRST) — every Claude id answers
  exactly what it did, which is what keeps the family-keyed
  `ModelColorLedger` from re-keying; `ModelPalette` takes the harness, or
  Codex models would wear Claude's terracotta. PRICING: one download serves
  every harness (`PricingFeedCache` at the bundle root, 24 h automatic /
  60 s behind a click, bytes cached only after they decode). UI: the panel
  strip groups by harness (a heading carrying the mark once for a harness
  with several accounts; a lone account wears the mark itself), Settings →
  General has a Harnesses card with a display-only Show switch, API Cost
  groups rates per harness with the unseen tail folded, and the privacy card
  carries one block per metered harness. R6: `FuzzyMatch` (core) behind
  `ModelSearchPicker`. CLI: `harnesses` noun; selectors are flat keys;
  `--provider` narrows and disambiguates; deep verbs gate on the SELECTED
  account's harness BEFORE projecting. TUI: mirrors decode the new fields,
  `--status` draws a block per shown harness and the header carries the
  others' digits; browsing accounts with tab and pinning from the pane are
  deferred. Hatches: `--fake-harnesses`; snapshot cases `statusitem-harnesses-*`
  (APPENDED last — the gate compares the old sidecar as a PREFIX).
  A LIMIT IS WHAT ITS WINDOW SAYS (user-reported the day this landed): in
  2026-09 Codex began reporting ONE window of 10080 minutes in `primary`
  with `secondary` null, and the slot-based reading called a week "Session
  (168h)", tagged it `S`, and the bar padded it out to `S35·W–·M–`. Two
  rules since. (1) `LimitWindowKind` (Formatting/) classifies a BARE window
  by its length — kind, rank, label ("Weekly", never "168h";
  `UsageFormatting.windowName`), and `UsageFormatting.tag(for:)` reads the
  bar letter off the same window, so label and letter cannot disagree. A
  provider whose vocabulary NAMES its limits (Claude) keeps its own word; a
  payload slot decides nothing except for a window that states no length.
  (2) `menuBarSegments` emits one segment per limit the account HAS — a
  meter with no number yet keeps its dash, a limit that doesn't exist draws
  nothing (and the CLI `prompt` line with it). Forms index segments by
  position, bounds-checked; a LONE limit is the outer ring and a centred
  bar, while two limits keep the historical three-row bars frame (pinned).
  `Profile` IS NOT `Identifiable`, on purpose: its `id` is the storage id,
  `default` for every harness, and SwiftUI keyed three harnesses' Settings
  rows as ONE row (every row read the first account, and a form pick landed
  nowhere visible). Every `ForEach` over profiles names `id: \.key`; the
  compiler enforces it. `--snapshot` writes `accounts-in-bar.png`.
  WHAT THE RENAME THEN BROKE, same day, all user-reported off one Codex
  card — read these as the cost of renaming a meter: (a) HISTORY IS KEYED
  BY LABEL, so the renamed meter lost its percent line, its forecast and
  the scale its model curves read (they fell back to "busiest model fills
  the plot": Astra at 100% on a 35% meter). `UsageProvider
  .currentMeterLabel(forStored:)` (identity by default) is the seam, and
  `UsageHistory(relabel:)` applies it on READ in all three readers (engine,
  `DigestClient`, `usage-cli history`); the engine appends to what it
  loaded, so the file heals with no migration. (b) `DigestClient` takes TWO
  ids — `profileID` is the flat KEY (digest section, socket verbs),
  `storageID` names the directory. Handed only the key it read
  `codex/codex/`, which doesn't exist: a store with a forecast (from the
  digest) and no samples (from disk). Exactly the rule above, broken by the
  fix that introduced the key. (c) `WeeklyProfile.historySpan` is WATCHED
  time — the sum of sample gaps ≤ `maximumGap` — not oldest-to-newest: a
  day of samples in August and a day in September spanned five weeks, read
  as "ready", and a rhythm learned from almost nothing erased a correct
  crossing. (d) A harness MARK is sized by its ink
  (`StatusItemRenderer.glyphFont`, scaled to fill the bundled mark's ink in
  both dimensions, ≤1.5×; the bundled mark scales by exactly 1) — ⬡ at the
  digits' point size drew visibly smaller than the designs. `--snapshot`
  writes `meter-<key>.png` for every shown account that isn't focused; a
  non-focused harness had no picture at all, which is how (a) and (b) hid.
  A CLICK'S EVENT DOES NOT SAY WHERE THE CLICK WAS (same day, found with the
  `--click-log <file>` hatch after reading the code found nothing): on this
  macOS the mouse-up a status item's action fires on reports the button's
  exact CENTRE as `locationInWindow`, whatever was clicked, so every bar
  click resolved to the cell in the middle. `pointerLocation(for:in:)` reads
  `NSEvent.mouseLocation` for mouse-down/up and trusts the event only for
  moves. MARKS: a mark at any size but the bundled one at the digits' size is
  a `.mark` run — centred on its INK and stroked in its own colour
  (`markStroke`), drawn by `StatusItemRenderer.drawMark` through CoreText at
  an exact BASELINE, never `draw(at:)`: that places a line box, and where
  the baseline falls inside it depends on which FALLBACK font serves the
  glyph (none of these marks is in the system font), so descender maths
  tuned until ⬡ sat right left ✳︎ riding high (user-reported), since an outline glyph's hair stays a hair at any size; in
  a bar of SEVERAL harnesses every mark is a heading and draws
  `headingScale` larger, keyed on `model.groups.count > 1` and never on the
  code path (`groupRuns` also draws the pinned one-harness multi-account
  bar). The panel's tiles and strip heading draw the same rule through
  `HarnessMark`. ACCOUNTS ARE ONE KIND OF THING: the strip is titled
  "Accounts" always, and `registry.rowTitle` names a row by ONE rule — a
  lone account by its agent with the sign-in beside it when known, an
  account under a heading by its own label (Codex/Gemini show no sign-in
  because their credential files are never read, §10 — not because they are
  a different entity). The strip header's form control is a three-way menu
  and stays visible in the stacked form, which used to hide its only
  in-panel way back. Settings → Accounts follows: a card per METERED harness
  (`registry.accountHarnesses`, hidden ones included), a one-home harness's
  single account among them with no folders to add and a footer saying why
  it shows no sign-in; `multiHomeHarnesses` now only gates discovery.
  `--snapshot` writes `accounts-cards.png`. THE NAME: `AppIdentity
  .displayName` ("Agent Usage", user-directed — it meters every coding
  agent) is what window titles, the panel footer, the Quit item and
  `CFBundleName` say. In 0.101.0 the wire name, bundle id and bundle file
  name stayed behind as identities; 0.102.0 moved them too
  (`docs/WORKFLOW.md`, "The rename").

## Brand accent is provider data

- THE ACCENT COLOR (opener restored 2026-09-20; the bullet had lost it)
  is provider DATA like the glyph — `UsageProvider.accent:
  ProviderAccent` (pure sRGB components; UsageCore stays UI-framework-
  free): Claude terracotta #D97757, Codex OpenAI-green #10A37F, Gemini
  blue #4285F4. App side (0.25–0.100.x): `ProviderStyle` facade,
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

## Codex (v0.27.0)

- CODEX PROVIDER (2026-08-15 v0.27.0, first non-Claude harness):
  `CodexProvider` (UsageCore/Providers/Codex/CodexProvider.swift) is LOCAL-FILES-ONLY —
  zero network destinations, zero credentials (`StaticCredentialSource`
  returns an empty token so UsageService stays byte-identical;
  `~/.codex/auth.json` is NEVER read, spec §10 amendment). Meters come
  from the newest `token_count` event's `rate_limits` in
  `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (two BARE windows, classified by length since 0.101.0 —
  historically primary=300min session, secondary=10080min weekly; used_percent + resets_at epoch-seconds;
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

## Gemini (v0.28.0)

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

## The registry, and what v0.101.0 retired

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
  defers its switch until the panel closes — ALL RETIRED by 0.101.0, which
  meters every detected harness and never switches. Metering pickers lived in the
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

## Account presence and attribution (v0.89.0)

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
