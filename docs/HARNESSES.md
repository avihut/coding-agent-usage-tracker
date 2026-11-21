# Harnesses and accounts

Every coding agent on this Mac is metered at once. This doc holds how a
harness is identified, keyed, stored and focused, plus what each shipped
provider actually does.

**Read this before** adding a provider, touching anything keyed by an
account or a harness, or changing focus, storage scopes or identity.

The extension point itself — `UsageProvider` and what may name a vendor —
is in [ARCHITECTURE.md](ARCHITECTURE.md#the-provider-seam). Adding a
provider also needs a spec §10 amendment for its hosts and local trees.

## What the user sees

### Several agent homes, one meter each

Claude Code keeps one config home per `CLAUDE_CONFIG_DIR`, and this Mac
runs two at once — work in `~/.claude`, personal in `~/.claude-personal`.
Since v0.96.0 the app meters each of them as its own **account**: its own
token, its own limits, its own history, its own directory under the app's
scope. There is no blending — two accounts are two meters, never one sum.

What this reads, and why it adds no network destination, is in
[PRIVACY.md](PRIVACY.md#several-agent-homes-no-new-destination).

The menu bar leads with whichever account you have actually been using:
focus follows the volume of session files over the trailing fortnight
(newest write breaks ties) — until you pick one, in the panel's account
strip, in Settings or with `a` in the TUI, which pins it until you ask for
Auto again (`A` in the TUI). Each
account draws in the menu bar in its own form — digits, bars, rings,
compact digits, or a dot — set per account or for all of them at once,
with the focused account optionally expanded to its full numbers whatever
its form, and any account can take a menu bar item of its own. Settings →
Menu bar shows the bar as it will draw, live, with every option pictured
in your own numbers; drag the accounts across the preview to order them.
Settings → Accounts is only about which sign-ins are metered.

The bar can also carry more than the meters. Settings → Menu bar has a
palette of elements to drag onto the preview (or click to add):
today's one element is **Runs out**, the expected time until a limit is
reached — `S 31m` in the same red capsule the digits alarm with, or once a
limit is spent `S↺ 2h 10m`, counting down to its reset. It is conditional
by design: while no limit is forecast to run out before it resets it draws
nothing at all, and the bar is exactly what it was without it. One element,
scoped — the earliest limit by default (any crossing cuts you off, so the
first one is the answer), or every limit, or one meter — placed before or
after the meters, per account or for all of them under the same "Same form
for every account" switch. With several accounts it draws for the focused
account only, so the bar carries one countdown; a switch gives every
account its own. Because a quiet day would make the drop look
like it failed, the preview draws a dashed placeholder where the element
will appear, and "Preview as if a limit were running out" dresses the whole
preview with a half-hour countdown so you can see the real rendering.
The panel gains an account strip that doubles as the selector — rows,
chips, or every account stacked. An account whose transcripts go quiet
for 30 days goes dormant and stops polling entirely until it is used
again.

On the command line, an account is a selector rather than a mode:

```sh
usage-cli accounts                       # id, label, home, state, focus, limits
usage-cli limits --account personal      # by id, nickname, label, or home path
CLAUDE_CONFIG_DIR=~/.claude-personal usage-cli limits   # the same answer
usage-cli state | jq '.profiles[] | {id, label, dormant, isFocused}'
```

`--account` wins over `$CLAUDE_CONFIG_DIR`, which wins over whichever
account is focused. Every existing noun answers for the selected account —
`limits`, `spend`, `sessions`, `history`, `windows`, `session` all read
that home's own files. An unknown selector exits 20 and lists the accounts
it knows; it never quietly answers for a different one, which is the whole
point when a status line renders under one config dir and the daemon is
metering another.

### Every agent at once, none of them "active"

Up to v0.100.1 the app metered ONE agent: it scored which harness had run
recently and read that one, and a picker let you override the guess. Since
**v0.101.0** it meters every harness it finds on this Mac — Claude Code,
Codex and Gemini CLI together — the way it already metered several Claude
accounts together. They sit alongside each other in the bar under their own
marks in their own colours, one of them holds focus, and the panel, the
charts and the CLI answer for whichever that is. There is no active harness
to choose and no switch to make.

A harness you aren't interested in can be **hidden** (Settings → General →
Harnesses). Hiding stops it being DISPLAYED and nothing else: it keeps being
polled, forecast and priced, and its models stay in the API Cost rates list,
which lists every detected harness whether shown or not. The last shown
harness can't be hidden — an empty bar isn't a state worth being able to
reach.

Metering them together adds no network destination either —
[PRIVACY.md](PRIVACY.md#every-harness-at-once-no-new-destination).

Forecasts stay per harness and per account folder. A folder's learned
history belongs to the folder, so signing into a different account inside
one keeps that folder's rhythm — the usage being pulled changed, not the
place it is kept.

`usage-cli harnesses` is the scriptable view: every detected harness, what
it has been doing lately, whether it is shown, and its own service health.
A deprecated harness carries its provider's note in the last column (`note`),
and the same words appear under it in Settings → General → Harnesses.

### Antigravity CLI

Since 2026-11-21 the app also meters **Antigravity CLI**, under a violet `∩`.
Its tokens, models and activity come from its own transcripts with nothing
to set up. Its PLAN LIMITS (Gemini session and weekly, and the separate
Claude + GPT pool) live only on Google's servers; the CLI shows them to a
custom status line, so to see them you make the app's export your status
line once:

```sh
usage-cli export-statusline antigravity --print-config   # prints the entry
```

and paste what it prints into `~/.gemini/antigravity-cli/settings.json` —
the app never writes that file. Until you do, Antigravity shows tokens
without limits, and a harness with no limits to show never takes the bar's
lead unless you pin it. **Gemini CLI** is labelled deprecated: Antigravity
succeeds it for Google's plans, and it stays metered for API-key use.


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
  per-file mtime/size parse cache (version 1 then; 2 since sessions) in
  the provider's scoped dir. LOCAL-PROVIDER GATING: `networkDestinations.isEmpty` ⇒ no
  RequestLedger recording, no API gauge, no budget lockout, manual
  refresh bypasses the TriggerGate (a disk rescan needs no rationing).
  New `noLocalData` case on BOTH UsageClientError and UsageError ("No
  local <agent> sessions found yet") — without it a sessionless local
  provider rendered as "Network unavailable". Pricing: providers declare
  a `PricingFeedSelector` slice of the LiteLLM feed (claude=anthropic,
  codex=bare openai keys); codex ships an EMPTY bundled table (live feed
  or "—", never stale hardcoded guesses). `scopedTag` now reads
  `scopedModelName` as data (the last label-parsing claude-ism).
- COMPRESSED ROLLOUTS (2026-11-21, user-reported: the Codex heatmap in
  "All" showed two weeks). Codex compresses a rollout once it has gone 7
  days without a write — zstd level 3 into a `rollout-compress-*.tmp` in the
  same folder, mtime copied, published no-clobber as `<name>.jsonl.zst`, and
  only then the `.jsonl` deleted — and re-inflates it to plain to resume it
  (openai/codex `codex-rs/rollout/src/compression.rs`). The scanner took
  `.jsonl` only, so a session's tokens, cost, card and heatmap days vanished
  the day Codex compressed it: history shrank daily, and on the reporting
  Mac 801 of 1,569 rollouts were already gone. Every reader now goes
  through `CodexRollouts.lines(of:)` — the activity scan, session detail,
  the meter walk — and a `.jsonl.zst` reads exactly as its plain form
  through the app's own decoder ([MEASUREMENT.md](MEASUREMENT.md) →
  Compressed transcripts). IDENTITY, NOT PATH: a rollout is its name minus
  `.jsonl[.zst]` (`CodexRollouts.rolloutID`) — which is also its session id,
  so the id survives compression — and the scan aggregates ONE record per
  id (`CodexActivitySource.onePerRollout`): readable before undecodable,
  then plain before compressed. That is Codex's own rule (its readers
  resolve "the plain rollout before its compressed sibling"): both names
  exist at once for a moment at compression and at resume, and the plain
  copy is then the original or the live, appended one. `sessionDetail`
  tries the plain file, then its twin. The parse cache stays version 2;
  why is in MEASUREMENT.md. Measured on the reporting Mac against the
  pre-fix scanner: 8 → 38 active days (Feb 7 → Nov 18), 737 → 1,528
  sessions, 7.62 B → 10.95 B tokens; every one of the 737 sessions the old
  scanner saw is identical in the new scan, and the token difference is
  exactly the 791 compressed-only sessions'.

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

## Antigravity CLI (2026-11-21)

- ANTIGRAVITY PROVIDER (user-directed; plan and investigation in
  `docs/plans/antigravity.md`, spec §10 amendment 2026-11-21):
  `AntigravityProvider` (UsageCore/Providers/Antigravity/) is
  local-files-only like Codex — zero network destinations, a
  `StaticCredentialSource`, and NOTHING credentialed opened.
- DISCOVERY BY NAME, NEVER BY OPENING: conversations are the `.db` names in
  `~/.gemini/antigravity-cli/conversations/` (id characters allowlisted
  before one becomes a path). A database is never opened — a WAL database
  opened without its `-shm` creates one inside the agent home. For each id
  the step log at `brain/<id>/.system_generated/logs/transcript.jsonl` is
  built directly: every walker skips hidden directories, and walking
  `brain/` would wander its worktrees (which hold decoy transcripts).
- TOKENS (`AntigravityActivitySource`): a row is a call when it states a
  `model` and both `input_tokens` (uncached) and `output_tokens` (thinking
  included); `cache_read_tokens` is cache read, cache creation 0. Verified
  call-for-call against the conversation databases during the
  investigation. The model's effort suffix is stripped from an ALLOWLIST
  (minimal/low/medium/high/xhigh — not `max`, a model-name word as in
  `gpt-5.1-codex-max`), never by dropping the last word, so
  `gemini-4-argon-trial` stays itself. Prompts = `USER_INPUT` rows whose
  source is `USER_EXPLICIT`. A forked conversation copies its parent's
  steps, so calls are claimed by value, in path order — the same call in
  two files counts once (`docs/MEASUREMENT.md`). A read that fails is never
  cached as an empty file. Display is Gemini's grammar first, then
  Claude's and Codex's (`ModelCatalog.union`); prices come from the feed's
  gemini, anthropic and openai slices, for the models the third-party pool
  runs.
- LIMITS (`AntigravityQuota`) come from the person's status-line export,
  `<bundle>/antigravity/default/statusline-export.json`, written only by
  `usage-cli export-statusline antigravity` (`StatusLineExport`, core —
  vendor-neutral: a provider declares `statusLineExport`, with its reducer,
  its change test and the settings snippet `--print-config` prints).
  Buckets map by id, window length from the id, never from
  `reset_in_seconds`: `gemini-5h` → "Session (5h)" (rank 0, S),
  `gemini-weekly` → "Weekly" (rank 1, W), `3p-5h`/`3p-weekly` → scoped
  "Claude + GPT (5h)" / "Claude + GPT (7d)" (rank 2, C). The pool's labels
  never repeat "Session"/"Weekly", so `usage-cli limits session|weekly`
  still names one meter (substring selection). Labels are history keys —
  renaming one is a data migration. `fetchedAt` is the reading's capture
  time, so an old export reads as old. A window whose reset passed with no
  newer reading shows a DASH and no reset, unless no conversation is KNOWN
  to have been written since the reset (then 0% — nothing could have been
  spent); no write time, or a cached body fetched before the reset, is a
  dash. The reducer is lenient per field and per bucket (a surprise drops
  only itself), bounds every number it keeps, and reads a bucket that
  states a reset but omits its fraction and any amount as SPENT (protobuf
  JSON drops a zero) — unverified until a real payload is captured.
- TWO POOLS, ONE ACCOUNT (`Meter.modelScope`, core, additive in the
  digest as `LiveMeter.modelScope`): the Gemini meters count `gemini`
  models and the pool's count `claude` and `gpt`, in the curves, the
  activity strip and the forecast overshoot. `PredictionEngine.lockouts`
  lets a shorter meter gate a longer one only when it covers every model
  the longer counts (unscoped, or the same scope), so a spent Claude + GPT
  session leaves the Gemini weekly's forecast running. Without a stated
  scope, `countedScope` derives one from `scopedModelName` exactly as
  before.
- MEASURED on the person's Mac, read-only (the opt-in
  `ANTIGRAVITY_LIVE_HOME` suite): 9 conversations, 92 calls, 17.06M tokens,
  8 prompts, matching a `jq` pass over the same files exactly; nothing
  under `~/.gemini` changed. The export command: 0.27 s, 11 MB.
- FOCUS AMENDMENT (vendor-neutral, `HarnessFocusRule`): a harness whose
  eligible accounts have all READ their usage and hold no limit
  (`reportsMeters == false`) isn't ranked unless pinned; when every
  eligible harness is like that the ranking runs over all of them. An
  engine that hasn't read yet answers from its cached last fetch (so a
  launch never leads, even briefly, with a harness that had nothing to
  show); one with no snapshot and no cache counts as having limits —
  never demoted on a guess. The host re-runs focus when that
  changes (`MeteringHost+Focus`), and local providers skip the launch
  stagger: a disk read has nothing to spread, and waiting would let a
  not-yet-read harness lead for minutes.
- GEMINI CLI DEPRECATED: `UsageProvider.deprecationNote` (default nil) →
  the digest's `HarnessState.deprecationNote` (additive, omitted when nil)
  → a caption on the Harnesses card row and `usage-cli harnesses`'s last
  column. The words live in `GeminiProvider`; the app names no vendor.

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
- PLAN NAMES (2026-11-21): vendors rename plans without touching the raw
  facts — on 2026-10-30 Anthropic's Max 5x became "Max" and Max 20x
  "Ultra" while the credentials still say `max` + `default_claude_max_20x`.
  So a provider names the plan (`PlanInfo.displayName`) and the label
  prefers that name over one built from type and tier. Claude:
  `ClaudePlanName` takes `oauthAccount.planDisplayName` (same key, same
  read-only file as the identity) and falls back to mapping the renamed
  tiers. Codex: `CodexPlanName` maps the `plan_type` ids Codex knows
  ("prolite" → "Pro Lite"). The digest carries it as
  `engine.planDisplayName` (additive) so a client-mode app keeps it.
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
