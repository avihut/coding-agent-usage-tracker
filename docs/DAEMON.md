# The engine, its hosts, and consumer interfaces

Status: **SHIPPED through v0.66.0** — digest (v0.65.0), then usaged +
lease + control socket + app host/client modes (v0.66.0). The spec §10
amendment is IN FORCE (docs/SPEC.md). Design decided 2026-08-16
(user-directed). Install remains opt-in: `usage-cli daemon install`.

## Why

The app grew a second consumer: a full-screen TUI pane (Rust/ratatui) for
tmux layouts, and later possibly more. Exactly one process may poll the
usage endpoint, write caches, and learn cadence — so the orchestrator
became an embeddable core engine with thin faces in front of it.

## The pieces

- **`UsageEngine`** (UsageCore/Engine/) — THE engine: refresh gate,
  429 backoff, adaptive cadence, FSEvents watcher, transcript scans,
  predictions, pricing, color-ledger seeding. One instance per host
  process. Hosts inject a `UserDefaults` domain and forward their wake
  signal to `noteWake()`.
- **Hosts.** Today: the menu bar app (façade `UsageStore`). Next: `usaged`,
  a launchd user agent that runs the engine headless so the TUI works with
  the app closed. Whoever hosts the engine runs ALL of engine + publisher
  (+ socket + lease once they exist). The app keeps an embedded fallback:
  no daemon → the app hosts; daemon appears → the app yields (daemon wins).
- **`live-state.json`** — the state fan-out. The engine's publisher rewrites
  it atomically (temp + rename) at every landing point: fetch completion
  (the heartbeat), prediction pass, transcript scan, pricing refresh,
  settings changes. Consumers stat the mtime and re-render; freshness of
  the file IS the engine's liveness signal.
- **Control socket** (next phase) — a hand-rolled unix-domain socket beside
  the digest for the few commands a consumer can issue (manual refresh,
  interval, provider switch, settings nudge). Local-only, 0600, NDJSON.
- **Clients.** The TUI is a digest client ONLY: it computes nothing,
  fetches nothing, writes nothing, holds no credential. The app in client
  mode (once the daemon exists) additionally reads core artifacts
  (history.json, window-ledger.json) read-only — the `usage-cli
  persistCache: false` precedent.

## The digest (`live-state.json`)

Path: `~/Library/Application Support/com.avihu.ClaudeUsage/live-state.json`
— the bundle root, above the provider scopes: one engine, one file.

Schema: `LiveState` (UsageCore/Digests/LiveState.swift), pinned by
`LiveStateTests` and by golden fixtures in
`Tests/UsageCoreTests/Fixtures/digest/` that the Rust TUI's serde contract
tests decode verbatim — the cross-language drift firewall. Discipline is
SyncDigest's: **additive-only forever**; readers ignore unknown fields;
absent ≠ zero (unpriced cost and unreported percent are nulls, never 0).
Regenerate goldens deliberately: `UPDATE_GOLDENS=1 swift test --filter
LiveState`, then read the diff.

Contents, by section:

- `engine` — provider identity (id, names, glyph, accent sRGB), plan label,
  app version, pid, host kind (`app`|`daemon`), generatedAt / fetchedAt /
  nextPollAt / backoffUntil, stale flag, local-provider flag, API budget
  used/ceiling (null for local providers), gate floor, pre-phrased error
  text + hint.
- `meters[]` — id, label, menu-bar tag, percent, level, resolved risk sRGB
  (RiskRamp), resetsAt + limit window, scoped model name, pre-phrased
  captions ("resets in 2h 12m", "runs out Sat 14:00"), forecast mirror
  (projected-at-reset, exhaustsAt, verdict, severity, ≤48-pt trajectory),
  window-scoped percent series (≤120 pts, reset cliffs drawn as
  hold-then-fall), grace-stitched activity stretches (exhausted tail
  flagged).
- `menuBar[]` — the S/W/scoped triple with resolved colors; doubles as
  `usage-tui --status` input.
- `models[]` — today's models, heaviest first: id, display name, ledger
  color (ModelColorMath — same math as the app's palette), tally, cost
  (null = unpriced).
- `activity` — today's hourly buckets (tokens + cost), trailing ~12 months
  of day totals + prompts, per-model day tallies for ~35 days, per-day
  hourly buckets inside timeline retention (~8 days). Beyond each horizon
  a drill degrades to what exists, labeled.

Privacy: the digest never contains tokens/credentials, full filesystem
paths, prompt text, or session titles. It stays on this machine — nothing
transports it; it is unrelated to the CloudKit sync digest (docs/SYNC.md).

Inspection: `usage-cli state` prints the file verbatim (and warns if it no
longer decodes). `usage-cli state | jq .menuBar` etc.

## The host arbitration (shipped v0.66.0)

- `engine.lock` — an exclusive `flock(2)`: whoever holds it runs engine +
  publisher + socket. The kernel releases on death, so a held lease is
  always a live process and stale locks cannot exist.
- `daemon.alive` — touched by usaged every 2s from first breath: how a
  lease-holding app learns a daemon wants the engine (the daemon can bind
  nothing while the app holds the lease).
- The app's role check runs every 30s (and on wake): hosting + fresh
  marker → shut the embedded engine down, release the lease, flip to
  client. Client + heartbeat stale beyond max(2× the digest's own poll
  horizon, 3 min) + lease free → take the lease, host embedded, seed the
  refresh gate from the digest's fetch stamp (never double-poll inside
  the floor); a takeover inside the floor presents the cached snapshot
  immediately instead of a loading shell.
- Control socket commands: status, refresh (gate-enforced), setInterval,
  setProvider, settingsChanged, refreshPricing, scanNow, shutdown.
- `usaged` (Sources/usaged/, embedded at ClaudeUsage.app/Contents/MacOS/):
  RunAtLoad + KeepAlive + ThrottleInterval 10, signed with the app's
  identity, IOKit sleep/wake (sleep acknowledged immediately), daily
  auto-redetection. Installed ONLY by the user running
  `usage-cli daemon install` / `mise run daemon -- install`.
- Client-mode reads are read-only everywhere: digest, history.json,
  window-ledger.json, pricing cache, and transcript scans via
  `scanTranscriptsReadOnly` (parse caches never written).

## Spec §10 amendment

IN FORCE since v0.66.0 — the authoritative text lives in docs/SPEC.md §10
("Engine host + consumer interfaces", 2026-08-16): one engine-state
artifact (`live-state.json`), one control socket + the two arbitration
artifacts, exactly one user-installed launch agent under all §10 rules,
and the lease-holder-is-sole-writer rule.
