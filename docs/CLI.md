# usage-cli

The scriptable face. Everything here is answered from the digest or, for
the deep verbs, from artifacts on disk — never from the network, never
from a credential.

**Read this before** adding a noun, a field or a flag.

Exit codes are API: 0 ok (an absent VALUE is still 0), 11 non-claude
provider, 13 no digest, 19 bad query, 20 selector matched nothing, 21
stale under `--max-age`, 22 `health --check` while an incident is open,
23 `notices --check` while anything is pending.

## The query surface (v0.81.0)

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

## M2 deep verbs (v0.83.0)

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

## Consumer ergonomics (v0.84.0)

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

## transcript (v0.95.0)

- USAGE-CLI TRANSCRIPT (2026-09-06, v0.95.0): `usage-cli transcript <path>
  [field] [--fields …] [--raw|--json] [--unix] [--relative]` prices ONE
  Claude Code transcript named by path — the main file plus the
  `<id>/subagents/**` parts beside it — fresh through
  `TranscriptScanner.sessionSummary(at:)` (sessionDetail's first half,
  factored into `parseSession(at:id:collectRows:)` so the ownership rule
  stays one code path) and `DeepQuerySessions.entry(_:pricing:)` (the pass
  `index` runs per scanned session). WHY: the daemon indexes exactly one
  `projects` tree (~/.claude), so a session Claude Code writes under
  another config dir (any `CLAUDE_CONFIG_DIR` other than the default)
  has no shortlist row and no scan to fall back to — `session <id>` misses
  it forever, and `usage-cli account` names the OTHER account. This verb is
  the door that prices such a session with the app's own parser and rates;
  a Claude Code status line script is the intended caller — for any
  transcript outside ~/.claude/projects, backgrounded and cached. Field vocabulary =
  `session`'s in full (every deep field is live — never "add --all";
  `source` reads "transcript"); `--all`/`--no-scan`/`--background` are
  unknown flags here (19); a path that is no transcript, or holds no call
  and no prompt, is a no-match (20); a non-claude provider is 11 ahead of
  the body. Routed by `DeepQuerySessionsCLI.nouns`
  (sessions/session/transcript) — NOT in `DigestQuery.nouns`, a digest
  can't answer it; the catalog entry shares `session`'s (`sessionFields`),
  walked by DeepQueryTranscriptTests (`coveredElsewhere`). §10: a read of
  the one local file named on the command line and its subagent siblings;
  nothing cached, nothing sent. NOT done here: making the daemon index
  other config dirs — the account timeline (v0.89.0) is time-based, and
  two dirs active at once would need root-based attribution first.

## Daemon verbs

Not digest queries — these drive the launch agent, and are the stable
faces for it: `usage-cli daemon install|uninstall|start|stop|status`, or
`mise run daemon -- <verb>`. `usaged install|ensure|uninstall` makes the
binary its own installer (the plist points at whichever copy ran the
verb). `usage-cli state` prints the digest verbatim. The policy these
verbs enforce — automatic install, the sticky `daemonAutoInstall`
opt-out — is in [DAEMON.md](DAEMON.md).
