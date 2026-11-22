# Plan: an old limits reading reads as old, never as now

Branch `fix/stale-local-readings`. User-reported 2026-11-22: "My Codex account
is over and was reduced back to the free plan. Why is it still showing the old
limit and marking it as Pro Lite?"

## What is wrong today (read from the code)

- Codex writes `rate_limits` (with `plan_type`) only in `token_count` events,
  i.e. when the model replies. The newest reading on the reporting Mac is from
  2026-11-18 20:13 (plan `prolite`, weekly 75%). `CodexMeterBuilder` sets
  `Snapshot.fetchedAt` to that event's own time, and re-applies the aging rule
  (`resets_at < now` ⇒ 0%, no reset) on every poll. Nothing ever judges the
  READING's age.
- Every poll hands the engine `.live(snapshot)` with that 3-day-old
  `fetchedAt`. `DisplayState.isStale` is "not `.live`", so the reading is
  fresh to every face: white digits, "Updated Wed 20:13", "Pro Lite plan".
- `UsageEngine.recomputePredictions` runs `PredictionEngine.predictAll` on it.
  The samples are appended at POLL time (`UsageHistory.append(now:)`), so the
  recent-rate fit sees a flat line and the weekly's damped blend leans on the
  learned `WeeklyProfile` baseline × pace factor — which still projects a
  crossing: "runs out in 23h 19m · ≈64% over", a forecast from a number about
  an account that has since changed plan.
- Claude has the same class of bug in a different shape: a `.cached`
  snapshot (offline, backoff) keeps the LAST live recompute's predictions
  forever — they are only recomputed on `.live`.
- The CLI already met this once: `--max-data-age` (issue #8) exists because
  `--max-age` judges `generatedAt` while a local provider republishes
  days-old numbers. That guard is opt-in; the faces have nothing.
- The only other plan source is the token in `~/.codex/auth.json` — a
  credential file, never read (§10). Not an option.

## The rule (core, vendor-neutral)

New `ReadingAge` (`Sources/UsageCore/Api/ReadingAge.swift`, beside
`Snapshot`):

- **horizon = min(the shortest limit window the reading carries, 6 h)**; a
  reading whose meters state no window gets the 6 h cap.
- A reading is **OLD** when `now − fetchedAt > horizon` (strictly). It turns
  old at `oldAt = fetchedAt + horizon`. A `fetchedAt` in the future (clock
  set back) is not old — the age can't be read, and saying "old" would be a
  guess; the CLI's `--max-data-age` keeps refusing it as it does today.
- API: `ReadingAge.horizon(meters:)`, `ReadingAge.oldAt(fetchedAt:meters:)`,
  `Snapshot.oldAt`, `Snapshot.isOld(at:)`, `DisplayState.asOf(at:) -> Date?`
  (the snapshot's `fetchedAt` while old, else nil). Pure, no clock of its own.

Why these numbers:

1. **The shortest window term.** A reading older than its shortest window has
   outlived the window it measured — that window has certainly reset since,
   so the reading can't speak for the limit it read. (For a 5 h session this
   coincides with the existing roll rule.)
2. **The 6 h cap** for long windows. The weekly forecast's measured part, the
   recent-rate fit, reaches back 4 h (`Meter.rateWindow` for weeklies); a
   reading older than that has no observation inside the fit at all, and the
   forecast is the learned rhythm projected from a point the account has
   left. 6 h = that 4 h fit plus the slowest poll spacing a HEALTHY engine
   produces (the decayed cadence's 1 h `AdaptiveCadence.ceiling`, plus slack),
   so a slow-paced Claude account never flickers old between two good polls.
   Must stay above `AdaptiveCadence.maxActiveInterval` (2 h) and the 2 h
   backoff ceiling — pinned by a test.
3. Bias: a false "old" costs a grey cell and an "as of 13:02" on an agent not
   touched for six hours — true, and mild. A false "current" is the report.
   So the horizon errs short. Yesterday's reading is always old by morning; a
   lunch break never is.

Applies to every provider through `Snapshot.fetchedAt`, so no provider seam:
Codex's rollout reading, Antigravity's `/quota` reading while its probe isn't
asked or can't refresh (`fetchedAt` = the run's finish), a Claude cache served
offline (`fetchedAt` = the cached fetch). Gemini's count is re-taken each
poll (`fetchedAt` = count time), so it never ages — "a provider without the
concept unaffected" falls out of the data, pinned by a test.

## What OLD does

1. **No forecast** — `PredictionEngine.predictAll(…, readingAt:)` returns
   `[:]` for an old reading (new optional parameter; nil = no age known =
   today's behaviour, so every existing test is untouched). The one engine
   holds the rule; overshoots follow (no prediction ⇒ no overshoot).
2. **The engine clears what it holds** when a reading is old:
   `recomputePredictions` passes `snapshot.fetchedAt` (so a pass over an old
   reading lands `[:]`), and a `.cached` refresh whose snapshot is old clears
   `predictions`/`forecastOvershoots` (today a cached snapshot keeps the last
   live pass's forecast forever). NO age timer (review): the digest builder
   applies the rule at every publish and `UsageStore` applies it at every
   read, so the app is exact; a digest READER (TUI, CLI) sees the flip at the
   next publish — every poll, at most the decayed cadence's 1 h ceiling (2 h
   at the slowest chosen pace) late on a 6 h judgment. Stated in Assumed.
   With #42's launch change (the cached snapshot shown as `.live` at once,
   "stamped with THEIR fetch time — the faces say how old they are"), this
   rule is what makes the faces say it: a Mac that was off overnight opens
   on "as of yesterday", no forecast, until the first poll lands.
3. **The window still rolls as today** (`resets_at < now` ⇒ 0%, no reset):
   untouched, and old + rolled shows the rolled 0% AND the "as of".
4. **History is not touched**: samples of an old reading still append at
   poll time (see Found).

## Digest (additive only)

`EngineStatus` (so every section and the projected top level carry it):

- `asOf: Date?` — present only while the reading is OLD, equal to
  `fetchedAt`; nil when fresh, when there is no reading, and from writers that
  predate the field (read as fresh). Same vocabulary as #42's
  `activityStatus.asOf` (present ⇔ the face says "as of").
- `asOfCaption: String?` — the pre-phrased "as of Wed 20:13"
  (`UsageFormatting.asOfText` = "as of " + the existing day-aware
  `updatedStamp`), so the TUI and the CLI print the app's words — "consumers
  render, they never compute" (DAEMON.md).
- While `asOf` is set every `meters[].forecast` and `risk`, and every
  `menuBar[]` severity/risk/`exhaustsAt`, are absent — they come from the
  (now empty) prediction map, and the builder also applies the rule itself
  at `now`, so a publish from any path (scan landing, threshold edit) can't
  carry a forecast past the horizon.
- `MenuBarCell.stale` widens to "cache-served, errored, OR an old reading"
  (composer: `engine.stale || engine.asOf != nil`). An older face reading a
  newer digest greys the old cell — the desired degradation. Documented in
  DAEMON.md.
- `engine.stale` keeps its meaning, so `status --check`, `status stale`,
  the prompt's " stale" marker and every exit code are unchanged.
- Goldens: the two existing goldens stay BYTE-IDENTICAL (nil optionals are
  omitted; checked by regenerating and `git diff --exit-code` on them). Both
  carry `fetchedAt` 2 min behind `generatedAt` in every section, so the rule
  can't trip them. The old reading gets a THIRD golden,
  `live-state-v1-old-reading.json` (Claude focused and fresh, Codex old —
  the reporter's shape), written by a new Swift test through the builder and
  composer and decoded by a new Rust contract test. Not the harness golden's
  Codex section: `demo-digest.py` templates Codex from it, and #42 edits
  those two files. `DigestFreezeTests` reads main's goldens by name, so a new
  file has no baseline to hold — additive by construction.
- Fixture inventory (review): the 59 `fetchedAt:` sites in Tests — digest
  builders use `fetchedAt` ≈ `now` (2 min); the headroom/CLI tests with old
  `fetchedAt` (14.5 h) construct `EngineStatus` directly, and the CLI reads
  `engine.asOf` rather than re-deriving it, so they stay as they are; history,
  cadence and continuity tests never reach the builder. The app's `--fake-*`
  hatches build digests from the live one (`LaunchHatches`) and the
  status-item `cmp` cases from static models, so no PNG moves. The full suite
  confirms it before anything else is changed.

## Faces

Swift app (both modes read `store.state`; client mode rebuilds the snapshot
from the digest, so `state.asOf(at:)` answers with the same rule there):

- `UsageStore.predictions` / `.forecastOvershoots` return `[:]` while
  `state.asOf(at: Date())` is set — covers a client reading an OLDER daemon's
  digest that still carries forecasts. Every Swift face that prints a
  forecast reads these (meter rows, popover, hover card, bar segments and
  Runs-out element, Settings → Usage "Projected at reset").
- Panel status row: lead reads "as of Wed 20:13" instead of "Updated …"
  (a cached+old snapshot keeps the orange "cached …").
- Meter rows: greyed (the existing `stale` look) and the caption gains
  " · as of Wed 20:13" after the reset text (or alone after a roll).
- Plan label: "Pro Lite plan · as of Wed 20:13" (checked for fit in the
  snapshot; see Assumed).
- Meter popover (`MeterHistoryView`): no trajectory/readout (no prediction);
  its caption/stats line carries the as-of.
- Account strip rows: greyed like a stale account.
- `UsageFormatting.profileStateLine` ("… · Updated Wed 20:13") — Settings →
  Accounts cards and `usage-cli accounts` — reads "as of Wed 20:13" for an old
  reading (new `old:` parameter; the CLI passes the section's `engine.asOf`).
- Bar: one-account path `stale: state.isStale || state.asOf(at: now) != nil`
  (`StatusItemRenderer.model(for:)`); multi-cell path reads the widened
  `MenuBarCell.stale`. Grey, ornament-free — the existing treatment.
- Hover card: forecast lines vanish with the predictions; stamp line, if
  any, says "as of".
- Kept on purpose: the bar's SPENT countdown (`S↺ 2h 10m`,
  `MenuBarCountdown`, percent ≥ 100 + a reset still ahead) — a measurement,
  not a forecast; the roll rule ends it at the reset. (Whether a stale cell
  draws it at all is checked in the snapshot.) Notices fire off sample DROPS
  (`NoticeDetector.grants`), never forecasts — nothing to gate.

`usage-cli` (core, from the digest's fields, exit codes unchanged):

- `status` human line, `limit <sel>` line: " · as of Wed 20:13" suffix
  (`withAsOfSuffix`, beside `withStaleSuffix`; only on limits-reading nouns —
  never on spend/cost, whose data is the fresh scan).
- `limits` table: each row's caption gains " · as of …".
- `prompt` (status lines): " as of Wed 20:13" after the segments, dimmed in
  colour/tmux like " stale"; `--json` payload gains `asOf` (additive).
- Fields: `status as-of` (date; null while fresh), `limit <sel> as-of`.
  `get engine.asOf` works already (raw JSON walk). Catalogs + DigestQueryFields
  walk updated.
- `--max-age` and `--max-data-age` unchanged. `headroom` unchanged: an old
  reading has no forecast, so `--forecast` can't refuse on it — callers that
  need fresh numbers already pass `--max-data-age` (documented in CLI.md).

TUI (Rust):

- `digest.rs`: `EngineStatus.as_of`, `as_of_caption` (serde default).
- `state.rs`: `Freshness::Old` (after offline/backoff/stale, before live).
- Header: status `○ as of Wed 20:13 · next in …` (hollow glyph, dim, like
  Stale); the plan `Pro Lite plan · as of Wed 20:13`; the Stale branch uses
  the caption when present instead of a bare clock (a 3-day-old cache read
  "as of 20:13").
- Limits: rows greyed (`grey` includes Old); captions gain the as-of.
- `--status` line: built from `menuBarCells` per shown harness, so an OLD
  cell (widened `stale`) is drawn unpainted — no level fallback colour, which
  today would paint an old 95% critical red — and its block ends in a dim
  " as of Wed 20:13" (the cell's section's `asOfCaption`, looked up by
  profile key). The focused block's " stale" marker is unchanged.

## Docs

HARNESSES.md (Codex: the age rule beside the aging rule; Antigravity
pointer), MEASUREMENT.md (Predictions: no forecast from an old reading),
TUI-PARITY.md, DAEMON.md (the two fields, the widened cell flag), CLI.md
(field, suffixes, headroom note), UI.md (stale treatment covers old). Release
note in the PR description (`## Release note`), never `.release-notes/next.md`
(the person's rule, 2026-11-22).

## Tests

- `ReadingAgeTests`: horizon min(shortest window, 6 h); no windows → 6 h;
  boundary (horizon − 1 s fresh, exactly horizon fresh, + 1 s old); future
  `fetchedAt` not old; the cap sits above `maxActiveInterval` and the
  backoff ceiling.
- `PredictionEngineTests`: fresh reading forecasts (same as with nil);
  old → `[:]`; boundary; `readingAt: nil` unchanged.
- Codex: old + rolled (expired window → 0%, no reset, and old).
- `LiveStateTests`: old → `asOf`, caption, no forecast/risk/segment
  severity; fresh → both nil; a cached+old Claude snapshot carrying stale
  predictions → none published; Gemini-like fresh snapshot unaffected.
- Composer: `MenuBarCell.stale` true for an old section.
- Engine: a pass over an old reading lands `[:]`; an old `.cached` refresh
  clears what a fresh pass left (stub provider, injected stamps).
- Golden: the third golden round-trips (Swift) and decodes (Rust); the two
  existing goldens unchanged.
- `profileStateLine`: "as of" for an old reading, "Updated" otherwise.
- TUI `--status`: an old cell unpainted + its block's as-of; focused stale
  marker unchanged.
- `DigestQuery*`: suffixes, `as-of` fields, prompt marker + JSON, exit codes
  and `--max-age` unchanged; fields walk.
- Rust: decode the golden's `asOf`; header/status-line/limits render the
  caption; `Freshness::Old`.

## Verify

- `mise run gate` green (full).
- Demo digest with an old Codex reading: `demo-digest.py --old-codex`
  (opt-in, drawn last so the other outputs keep their bytes) — Codex
  `fetchedAt` 3½ days back, Pro Lite, weekly 75%, `asOf` + caption, no
  forecasts, its cell stale. `--demo-digest <file> --snapshot`, dark + light
  PNGs. BOTH paths (review — HARNESSES.md records the non-focused path
  hiding seven bugs once): (a) Claude focused, Codex old — the reporter's
  view: the bar's Codex cell, the strip / stacked rows, `meter-codex.png`,
  the TUI header mini, the `--status` Codex block, `usage-cli --digest
  <demo> limits --account codex` / `status --account codex` / `accounts`;
  (b) Codex focused: panel status row, meter rows, plan label, popover.
- `usage-tui --digest <demo> --status` only (never engine keys).
- Optional, read-only: `usage-cli limits --account codex` / `status` against
  the live digest, to show what the person's real reading prints (after the
  daemon runs this build — it won't on this branch; so this shows today's
  output plus what the rule would say, computed by the CLI build from the
  digest's own `fetchedAt`/meters only if cheap — otherwise skipped and
  said so).

## Assumed (decisions taken without asking)

1. Horizon = min(shortest window, 6 h) — justified above. IN PLAIN WORDS:
   every local harness you haven't used for six hours reads grey with
   "as of …" — every morning, until its first reply (Codex), or until the
   probe next runs (Antigravity: when you next use it). That is the honest
   state, and it is what this change is for.
2. One stamp grammar everywhere ("as of" + the existing day-aware stamp),
   including the plan suffix; if the panel's plan suffix doesn't fit beside
   the status lead in the snapshots, the panel shortens it to the day part
   only ("· as of Wed") and says so in the PR.
3. `engine.stale` and every exit code keep their meaning; OLD is its own
   field. `MenuBarCell.stale` widens (it is the bar's "not current" bit).
4. History keeps appending an old reading's samples at poll time (Found).
5. `headroom` keeps its rules; documented instead. IN PLAIN WORDS: with
   `--forecast`, an old reading whose (meaningless) forecast was red used to
   refuse with 25; it now has no forecast, and a meter with no forecast
   passes the gate, so the same call exits 0 unless the caller also passes
   `--max-data-age` (which already refuses it with 21). cahoots, the
   motivating caller, should pass `--max-data-age` — not checked here (its
   config is outside this repo).
6. No age timer: a digest reader sees the flip up to one publish late (see
   "What OLD does" 2).
7. The TUI `--status` line stops painting level colours on an old cell (the
   bar's own "grey, ornament-free"); a CACHED (`stale`) cell keeps today's
   colours — not this change's bug.

## Found (belongs elsewhere — not fixed here)

- History records a local reading at POLL time, so the popover chart draws a
  flat line to now across an old reading's whole age, and the rhythm learns
  "no consumption" for those hours. Stamping samples at `fetchedAt` (and
  skipping repeats) is the honest fix, but it moves the rhythm attribution
  and the window ledger; its own change.
- The TUI's "updated HH:MM" (Live) is a bare clock: a reading from 23:00
  read at 01:00 says "updated 23:00". The digest carries no updated caption.

## Interactions

- #42 (`fix/daemon-under-load`) touches `LiveState.swift`, `ProfileState.swift`,
  `UsageEngine.swift`, `DigestClient.swift`, both goldens and the TUI's
  digest/state/ui — expect conflicts; its `activityStatus` is the activity
  SCAN's age, not the limits reading's, so nothing to reuse beyond the
  `asOf` vocabulary. Whichever lands second regenerates the goldens.

## As built (deviations from the plan above)

- TUI limits: the "as of" sits on the LIMITS title, not on every row — the
  column is fixed-width, so a per-row suffix clipped (and only shrank the
  bars). The app's meter rows carry it per row as planned.
- The panel's plan suffix fits beside the status lead in both themes, so
  Assumed 2's fallback (day-only) wasn't needed.
- Demo digest: `--old-codex` and `--focus-codex`, both opt-in; every other
  output is byte-identical to main's script (checked with `cmp`).
