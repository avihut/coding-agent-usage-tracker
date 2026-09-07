# The engine, its hosts, and consumer interfaces

Status: **SHIPPED through v0.96.0** — digest (v0.65.0), then usaged +
lease + control socket + app host/client modes (v0.66.0), the TUI
(v0.67–0.69), automatic installation (v0.70.0), and several agent homes
metered by one host (v0.96.0). The spec §10
amendment is IN FORCE (docs/SPEC.md). Design decided 2026-08-16
(user-directed). Install is automatic from the UI entry points; the
sticky `daemonAutoInstall` opt-out (Settings toggle,
`usage-cli daemon uninstall`) keeps it away deliberately.

## Why

The app grew a second consumer: a full-screen TUI pane (Rust/ratatui) for
tmux layouts, and later possibly more. Exactly one process may poll the
usage endpoint, write caches, and learn cadence — so the orchestrator
became an embeddable core engine with thin faces in front of it.

## The pieces

- **`UsageEngine`** (UsageCore/Engine/) — THE engine: refresh gate,
  429 backoff, adaptive cadence, FSEvents watcher, transcript scans,
  predictions, pricing, color-ledger seeding. Since v0.96.0 one instance
  per METERED HOME rather than per process, and everything a home does not
  own by itself — the status poller, the pricing service, the notice
  ledger, the update checker — moved out into a shared `ProviderServices`.
  Hosts inject a `UserDefaults` domain and forward their wake signal to
  `noteWake()`.
- **`MeteringHost`** (UsageCore/Engine/, v0.96.0) — what a host actually
  runs: the lease, the socket, the publisher, the network monitor, one
  `ProviderServices` per provider and one `UsageEngine` per enabled home,
  launches staggered by the gate floor so N homes never poll in one burst.
  It owns focus, dormancy (a home quiet for 30 days stops its engine and
  revives on the first write under its own tree), and the compose step that
  turns N sections into one digest.
- **Hosts.** `usaged`, a launchd user agent that runs the metering host
  headless so the TUI works with the app closed, and the menu bar app
  (`ProviderRegistry` + a per-home `UsageStore` façade). Whoever hosts runs
  ALL of it — host, publisher, socket, lease. The app keeps an embedded
  fallback: no daemon → the app hosts; daemon appears → the app yields
  (daemon wins).
- **`live-state.json`** — the state fan-out. The engine's publisher rewrites
  it atomically (temp + rename) at every landing point: fetch completion
  (the heartbeat), prediction pass, transcript scan, pricing refresh,
  settings changes. Consumers stat the mtime and re-render; freshness of
  the file IS the engine's liveness signal.
- **Control socket** — a hand-rolled unix-domain socket beside the digest
  for the commands a consumer can issue. Local-only, 0600, NDJSON, one
  request per connection.
- **Clients.** The TUI is a digest client ONLY: it computes nothing,
  fetches nothing, writes nothing, holds no credential. The app in client
  mode additionally reads core artifacts
  (history.json, window-ledger.json) read-only — the `usage-cli
  persistCache: false` precedent.

## The digest (`live-state.json`)

Path: `~/Library/Application Support/com.avihu.ClaudeUsage/live-state.json`
— the bundle root, above the provider and per-home scopes: one host, one
file, however many homes are metered.

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
  hourly buckets inside timeline retention. Beyond each horizon a drill
  degrades to what exists, labeled.
- `focusedProfile` / `profiles[]` / `menuBarCells[]` (v0.96.0, additive) —
  one section per metered home (id, label, monogram, tilde-abbreviated
  home path, enabled/dormant/focused, and its own engine/meters/menuBar/
  models/activity/sessions/accountPresence), plus the per-home menu bar
  triples the app draws as cells. The FOCUSED section is also projected
  onto the top level, so every field above keeps answering for the home in
  focus and a pre-0.96 consumer reads it unchanged. Absent lists mean a
  writer that meters one home — absent ≠ empty. A dormant or disabled home
  carries nil numbers, never zeros. The TUI mirrors both fields in its
  digest structs (the golden must decode) but does not draw them yet.

Privacy: the digest never contains tokens/credentials, full filesystem
paths, or prompt text — home paths appear tilde-abbreviated only. (Session
titles it does carry, under the v0.80.0 re-amendment: the same ones the
session index already materializes, nothing newly derived.) It stays on this machine — nothing
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
- Control socket commands, current as of v0.96.0: status, refresh
  (gate-enforced, targets the focused home), setInterval, setProvider,
  settingsChanged, refreshPricing, scanNow, refreshStatus, checkUpdates,
  markNoticesSeen, dismissNotice, dismissAllNotices, focusProfile (nil id
  clears the pin), refreshProfile, setProfileEnabled, profilesChanged,
  shutdown. One socket per host however many homes it meters; an app-hosted
  socket still refuses setProvider and shutdown.
- `usaged` (Sources/usaged/, embedded at ClaudeUsage.app/Contents/MacOS/):
  RunAtLoad + KeepAlive + ThrottleInterval 10, signed with the app's
  identity, IOKit sleep/wake (sleep acknowledged immediately), daily
  auto-redetection. Since v0.70.0 installation is automatic (spec §10
  re-amendment 2026-08-16): core `LaunchAgentInstaller` converges the
  agent — the app runs it at every launch, the TUI spawns
  `usaged ensure` when no engine publishes, and `usaged
  install|ensure|uninstall` make the binary its own installer (the plist
  points at whichever copy ran the verb). The sticky opt-out
  `daemonAutoInstall` is set false by `usage-cli daemon uninstall` and
  the Settings toggle, and every auto-install path honors it;
  `daemon install` / the toggle re-arm it. `ensure` also self-heals: a
  plist aimed at a missing or moved binary is rewritten, and a live
  daemon publishing an older version is kickstarted into the current
  one.
- Client-mode reads are read-only everywhere: digest, history.json,
  window-ledger.json, pricing cache, and transcript scans via
  `scanTranscriptsReadOnly` (parse caches never written).

## Spec §10 amendment

IN FORCE since v0.66.0 — the authoritative text lives in docs/SPEC.md §10
("Engine host + consumer interfaces", 2026-08-16): one engine-state
artifact (`live-state.json`), one control socket + the two arbitration
artifacts, exactly one launch agent under all §10 rules, and the
lease-holder-is-sole-writer rule. Re-amended the same day at v0.70.0
(user-directed): the launch agent auto-installs from the UI entry points,
with `daemonAutoInstall` as the sticky opt-out.
