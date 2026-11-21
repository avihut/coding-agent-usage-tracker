# Measurement: scanning, counting, pricing, forecasting

Where the numbers come from and what they are allowed to mean.

**Read this before** touching the transcript scanner, the cost
arithmetic, the pricing feed, or anything that talks about the future.

How these numbers are drawn is in [CHARTS.md](CHARTS.md); how they reach
a face is in [ARCHITECTURE.md](ARCHITECTURE.md).

## The transcript scan

- The activity heatmap reads Claude Code's local transcripts
  (`~/.claude/projects/**/*.jsonl`) via `TranscriptScanner` — strictly
  read-only, dedup by requestId, mtime/size cache in this app's own App
  Support dir — merged (`ActivityMerge`) with prompt timestamps from
  `~/.claude/history.jsonl` via `PromptHistoryScanner` (epoch-ms, no token
  counts, survives Claude Code's `cleanupPeriodDays` sweep): days with
  prompts but no surviving transcripts render faint as "no token data".
  Never write inside an agent home, never go near `.credentials.json` from
  the scanners, nothing leaves the machine — with ONE user-authorized
  exception (2026-08-14): the Settings → General transcript-retention
  control writes exactly `cleanupPeriodDays` in that home's `settings.json`
  through `ClaudeCodeSettings` (read-modify-write preserving every other
  key, atomic, refuses to touch a file whose content doesn't parse; per
  home since v0.96.0, the focused one from Settings). Nothing else ever
  writes there. The same scan also attributes
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
  `WindowTokens`.

## Compressed transcripts

- COMPRESSED TRANSCRIPTS (2026-11-21): Codex archives rollouts older than a
  week as `.jsonl.zst` ([HARNESSES.md](HARNESSES.md) → Codex), and macOS
  ships no zstd — the Compression framework has zlib, LZMA, LZFSE, LZ4 and
  Brotli. Zero dependencies rules out libzstd and shelling out to a
  Homebrew binary, so UsageCore carries its own read-only DECODER
  (`Sources/UsageCore/Compression/`, RFC 8878): frames, skippable frames,
  several frames per file, raw/RLE/compressed blocks, raw/RLE/Huffman
  (1 and 4 streams, treeless) literals, predefined/RLE/FSE/repeat sequence
  tables, repeat offsets, the XXH64 content checksum. NOT dictionaries — a
  frame naming one is refused. `LineReader` sits on top and yields lines
  exactly as `Data.split(separator: 0x0A)` did, for plain files too.
  IT RUNS IN THE DAEMON, over files this app didn't write: malformed,
  truncated or hostile input ends in a `ZstdError` — never a trap, a hang
  or an unbounded allocation. Every read is range-checked first; every loop
  is bounded by input bytes, a sequence count or the block's output budget.
  LIMITS: window ≤ 2^27 = 128 MiB (the reference decoder's own default, so
  any valid frame `zstd -d` takes without `--memory` decodes — two
  malformed shapes its fast paths tolerate are refused, as the RFC says: a
  Huffman stream with bits left over, a match past the window; the buffer
  is reserved at window + slack once, and only what a frame fills becomes
  resident), ≤ 1 GiB out per file (8× the largest
  plain rollout seen, 120 MB — bounds a decompression bomb's CPU), a line
  ≤ 64 MiB (~5× the longest real one, 13.6 MB; a longer line is skipped
  unbuffered). MEMORY: it streams a block (≤ 128 KiB) at a time and keeps
  only the window plus a slack; the compressed file is read in 256 KiB
  chunks, plain files in 1 MiB ones — neither is ever held whole any more.
  EVERY FILE READ DRAINS ITS OWN AUTORELEASE POOL: `FileHandle` chunks are
  autoreleased, and a thread with no pool of its own kept them all — 365 MB
  peak decoding the 801-file backlog, 24 MB pooled. Peak memory of a cold
  Codex scan fell from 490 MB to 110 MB, mostly from no longer reading
  120 MB rollouts whole.
  FAILURE: a stream that fails part-way counts for NOTHING, never half a
  file. Bad bytes are cached as `undecodable: <ZstdDecoder.revision>` —
  bump the revision with any change that could accept bytes an older one
  refused, or a compressed rollout (which never changes) stays skipped
  forever; and bump `cacheVersion` with any fix that changes the OUTPUT of
  a frame the decoder already accepted, since only `undecodable` records
  are retried (Codex writes no content checksum to catch it). A read
  failure (vanished, permissions, I/O) caches nothing: the next scan
  retries, and a record already held stands until then. The session detail
  view's reads stop when its task is cancelled; a scan's never do.
  CACHE: reading compressed rollouts needed no `cacheVersion` bump (it was
  2 then). `undecodable` is additive and optional, no record a plain file
  produces changed, and a `.jsonl.zst` path is simply new to the cache —
  while a bump re-parses the whole corpus (the cold-cache stampede above).
  An older build reading the new cache ignores the key and drops `.zst`
  paths. The one-time cost is parsing the compressed backlog on the first
  scan. KNOWN, AND OLDER THAN THIS: a client-mode app scans read-only over
  the daemon's cache, so while the app and the daemon are different builds
  whose caches disagree, the app re-parses what the daemon's cache lacks on
  every 60 s scan — with an older daemon, now the compressed backlog too.
  VERIFIED (2026-11-21, reporting Mac): all 801 real `.jsonl.zst`
  (348 MB → 1,631 MB) decode SHA-256-identical to `zstd -dc`, at
  ~200–240 MB/s in a release build; 207 differential inputs (text, binary,
  noise, tiny alphabets, runs, empty, block-boundary sizes × levels −1…−22,
  `--fast`, `--long`, small windows, raw literals, multithreaded, piped,
  concatenated) match `zstd -dc`. The review round added ~240K mutated
  streams (21K under AddressSanitizer) with no trap, hang or bad access,
  1,000 random encoder parameter sets, and a 17.5K-mutant differential
  against `zstd -d` in which this decoder never accepted what the reference
  refused once two refusals were added (a tree without a weight-1 pair,
  four Huffman streams under 6 literals). Cold scan 13.3 s (16.8 s before, over
  half the data), warm 0.40 s (0.23), cache 4.6 MB (2.8). Fixtures are
  synthetic (`mise run fixtures-zstd`), and a coverage test fails if any
  decoding path goes unexercised — an unhit path wants a fixture, never a
  dropped assertion.

## How a call is counted

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
  per-caller guard for anything polling on a timer. Since issue #24
  (docs/CLI.md) a miss against any digest no longer scans at all — it asks
  the engine, which answers nothing until its own scan lands — so a
  status line can't start this stampede; a non-holder's corpus scan is
  also one per account (`TranscriptScanLock`, exit 27 for the rest).
  The engine's own scan cadence: at most one a minute, and a transcript
  write inside that minute is owed ONE catch-up when it ends
  (`ActivityScanThrottle`) — the throttle used to drop it, and a turn's
  last write could sit unscanned until anything else in the tree changed
  (observed: five minutes). The call list also
  grew the cache 2.1MB -> 3.6MB.
  KNOWN, DELIBERATE 0.087% ABOVE ccusage: 1,510 lines state a
  `cache_creation_input_tokens` larger than their own 5m+1h breakdown; we
  bill the vendor's total, they bill the breakdown and drop the rest.
  NOT implemented and inert today: long-context (>200K) tiered rates —
  `ModelRates` has no `*_above_200k` and `PricingFeedClient.decode` drops
  those keys, so if the feed ever carries them for a model in use we
  under-bill silently. Same for a `speed: "fast"` multiplier (every
  entry in this corpus is `"standard"`).

## Antigravity's calls (2026-11-21)

- A row of a conversation's `transcript.jsonl` is one model call when it
  states a `model` and both `input_tokens` and `output_tokens`; there is
  no streaming restatement to collapse (one row per finished step).
  `input_tokens` is the UNCACHED slice and `cache_read_tokens` the cached
  one — disjoint, like Claude's; `output_tokens` already includes
  thinking. Cache creation is 0 (none is reported). Checked call for call
  against the CLI's own conversation store during the investigation, and
  92/92 calls and 17.06M tokens against a `jq` pass on the person's Mac.
- A forked conversation copies its parent's rows into its own file, so
  calls are claimed by VALUE (timestamp, model, the three counts),
  visiting files in path order: a call an EARLIER file counted is skipped,
  so the same call in two files counts once, in whichever sorts first.
  Nothing is deduplicated within one file. Prompts are skipped only in a
  file that shares a call with an earlier one (a fork): their stamps are
  whole seconds, and three `agy -p` runs started in the same second are
  three prompts.
- A row whose counts are negative or beyond 10^12 is no call (garbage, and
  summing it could overflow).
- Days are local days of each call's own UTC timestamp, through the
  injected calendar; the minute timeline keeps the scanner's 56 days.

## Cost estimates

- Cost estimates: `PricingTable` (per-token `ModelRates`, exact-id then
  date-stripped lookup) from `PricingService` — disk-cached LiteLLM feed
  refreshed when >24h old (attempted at most hourly, piggybacked on usage
  refreshes), `PricingTable.bundled` as the offline floor. Estimates are
  list-price counterfactuals; subscription plans don't bill per token.

## Predictions

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
  drop, moved reset, or gaps >48 h; bucket rates shrunk by `priorHours` = 8
  of pseudo-observation toward a STRUCTURED estimate — that weekday's mean
  rate × that block-of-day's mean rate ÷ the global mean (v0.99.3,
  user-reported: the flat global-mean prior put ~20% of a Sun–Thu user's
  modeled week into Fri/Sat and 00–08h blocks that had never spent a
  point, and flattened the busy blocks, which read a normal Tuesday as
  1.28× hot) — a day or hour never used forecasts zero by construction;
  scaled at predict time by a pace factor (actual+5)/(expected+5) clamped
  0.5–2 that DECAYS toward 1 with `paceDecayHours` = 24 (same closed form
  as the burst: a hot Tuesday steepens Wednesday's forecast, not next
  Monday's; the flat multiplier compressed the whole week's rhythm into the
  days before the crossing)), else the
  window's own average pace (percent ÷ elapsed, needs ≥30 min). LOCKOUTS
  (v0.100.0, user-directed): a meter whose `limitWindow` is STRICTLY
  shorter defines a hard zero on every wider meter — spent now → [now,
  its reset]; forecast to cross → [its crossing, its reset]; equal windows
  never lock out (the scoped weekly leaves other models free), nil windows
  neither issue nor receive — and inside a lockout the wider meter gains
  nothing (rhythm and burst alike), so its curve draws a flat plateau with
  a point at each boundary. `PredictionEngine.lockouts(on:from:
  predictions:now:)` is the pure rule; `predictAll` predicts shortest
  window first so each wider meter reads the fresh narrower forecasts,
  and it is the engine's ONE call — never predict a meter alone in the
  engine again. OVERSHOOT (v0.100.0, user-directed "how much extra usage
  will I need"): `UsagePrediction.projectedUnclamped` keeps the raw
  projection at reset (what the window would reach if its own limit did
  not bind; narrower lockouts still respected) beside the clamped
  `projectedAtReset`; `ForecastOvershoot.estimate` (Prediction/) turns the
  points over 100 into tokens through the popover's own conversion
  (`ModelCurves.windowPercentPerToken` over the window's gains, read off the
  window's OWN samples — `WindowSamples.percents`, picked by reset stamp, so
  the boundary poll still reporting the previous window's percent never
  enters this one's gains) and into
  dollars through the window's priced rows only (Anthropic bills extra
  usage at API list rates, which is what the app prices at) — tokens and
  cost are nil, never 0/$0, without token data or a priced model. Phrased
  ONCE in `UsageFormatting.overshootCaption` ("~$38 extra (≈11% over)",
  percent alone when unpriced) and appended by `forecastCaption(overshoot:)`
  to the reset line; the engine keeps `forecastOvershoots` beside
  `predictions`, the digest carries `MeterForecast.projectedUnclamped` +
  `.overshoot` (additive), `UsageStore.forecastOvershoots` is the app
  seam for both modes. Faces: panel caption, popover readout right of the
  crossing + stats line, Settings → Usage "Projected at reset", CLI
  `forecast.projected-raw|overshoot|overshoot-tokens|overshoot-cost`.
  Never drawn past 100 on a chart (the headroom is 15%; an overshoot can
  be 50%). Each
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
