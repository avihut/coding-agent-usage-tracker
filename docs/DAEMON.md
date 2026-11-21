# The engine, its hosts, and consumer interfaces

Status: **SHIPPED through v0.96.0** — digest (v0.65.0), then usaged +
lease + control socket + app host/client modes (v0.66.0), the TUI
(v0.67–0.69), automatic installation (v0.70.0), and several agent homes
metered by one host (v0.96.0). The spec §10
amendment is IN FORCE (docs/SPEC.md). Design decided 2026-08-16
(user-directed). Install is automatic from the UI entry points; the
sticky `daemonAutoInstall` opt-out (Settings toggle,
`usage-cli daemon uninstall`) keeps it away deliberately.

## Using it

The metering engine runs as a launchd user agent, `usaged` (embedded in
the app bundle), so consumer interfaces — the TUI, or the menu bar app
itself — render with nothing else open. The daemon wins: while it runs,
the app renders its published `live-state.json` digest and sends commands
over a local socket; quit the daemon and the app hosts the engine embedded
again within moments (`docs/DAEMON.md` has the full design).

Installation is automatic: the app sets the agent up at launch (and heals
it — a moved bundle is repointed, a daemon running a different build than
its binary on disk restarted), and the TUI does the same when it finds no
engine running at all — never for one that is merely busy. There is nothing to
approve: the daemon reads the Claude Code token through Apple's own
`security` tool — the same client Claude Code stores it with — so no
Keychain consent dialog ever appears.

```sh
mise run daemon -- status     # launchd state, digest age, socket ping, accounts
mise run daemon -- stop       # boot it out (plist kept)
mise run daemon -- uninstall  # remove it AND disarm auto-install (sticky)
mise run daemon -- install    # re-arm + reinstall by hand
usage-cli state | jq          # inspect the live digest
```

Opting out is deliberate and sticky: `uninstall` (or the Settings toggle
"Background metering engine") removes the agent and sets
`daemonAutoInstall=false`, which every auto-install path honors — the app
then simply hosts the engine embedded whenever it runs, exactly as before
v0.66.0.

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

Path: `~/Library/Application Support/io.github.avihut.AgentUsage/live-state.json`
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

Consumers RENDER, they never compute: the digest carries pre-phrased
captions and resolved colours, and a face that recomputes either will
disagree with the other faces. Colour and risk maths live in core
(`RiskRamp`, `ModelColorMath`).

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
- `allAgents` (2026-11-21, additive) — consumption summed across every
  account "all" counts (`ConsumptionMembership`: enrolled, enabled, awake,
  harness shown), every agent and model; never limits. `members` (profile,
  providerID, state `counted`|`scanning`|`noTokens`), a pre-phrased
  `countLabel`, `partial`, today's `models` and an `activity` shaped
  exactly like the top level's, so faces read it with the code they have.
  Built by the COMPOSER from each engine's raw scan (`ProfileSection
  .consumption`, set once `sessionsIndexed`) through `ConsumptionMerge` —
  the panel's own merge — and the per-account rollup's builder
  (`LiveStateBuilder.activity`): one answer. A member whose scan hasn't
  landed is `scanning`, named and left out, never zero; while NO member
  is counted, `models` and `activity` are absent (no total yet — never a
  total of zero). Rows are per
  agent + model, accounts of one agent summed, and carry `ModelRow.agent`
  (absent on every per-account row, so those encode byte-identically);
  colours are the agent's ledger slots by its own catalog's family,
  `ModelColorMath.agentShade` when several agents share the chart — the
  dark variant, as every digest colour is. Hourly
  buckets reach 8 days back — a SIZE cap (`AllAgentsDigest.hourSpanDays`;
  an account's own reach its scanner's 56-day retention). Absent when "all"
  holds fewer than two accounts (the focused section IS the total) or the
  writer predates it. Memoized on the host (`AllAgentsCache`, keyed on the
  day, where each horizon's cut falls, membership, scans, prices and
  ledgers): heartbeats reuse it; a miss rebuilds on the host's actor
  (~127 ms in a debug build on heavy synthetic data). Size on a
  three-agent Mac: the section is ~111 KB pretty, +16.7% on a 664 KB
  digest measured without it.

Privacy: the digest never contains tokens/credentials, full filesystem
paths, or prompt text — home paths appear tilde-abbreviated only. (Session
titles it does carry, under the v0.80.0 re-amendment: the same ones the
session index already materializes, nothing newly derived.) It stays on this machine — nothing
transports it; it is unrelated to the CloudKit sync digest (docs/SYNC.md).

Inspection: `usage-cli state` prints the file verbatim (and warns if it no
longer decodes). `usage-cli state | jq .menuBar` etc.

## The host arbitration (shipped v0.66.0)

- The arbitration itself is PURE (`EngineHostBroker`) and therefore
  unit-tested; the IO around it (`EngineLease`, `ControlSocket`,
  `StatePublisher`) is thin by design. Measured live at v0.66.0: an app
  yields in 10–14s, a client takes over in ≤35s, no double-poll across a
  handover, and meters come back instantly from cache.
- `engine.lock` — an exclusive `flock(2)`: whoever holds it runs engine +
  publisher + socket. The kernel releases on death, so a held lease is
  always a live process and stale locks cannot exist.
- The QUOTA PROBE (spec §10 amendment 2026-11-21, second) runs in the
  lease holder only: a host is given an `AgentCommandRunner` (usaged
  always; the app when it hosts, never under `--snapshot`), and its engines
  write the probe's state, `<bundle>/<provider>/<profile>/quota-probe.json`,
  like every other file there. The first amendment's carve-out — a
  status-line export written by `usage-cli` — is retired: the lease holder
  is again the sole writer of the scoped folders. A spawned agent tool
  gets no descriptor of the host's (`POSIX_SPAWN_CLOEXEC_DEFAULT`), so it
  can never hold `engine.lock` past its parent.
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
  shutdown, and (issue #24) `session(profile:id:)`. One socket per host
  however many homes it meters; an app-hosted socket still refuses
  setProvider and shutdown.
- `session` is the one READ-ONLY verb that returns data: the named
  profile's engine answers an id prefix from its in-memory index (every
  session its last scan holds, not only the published eight) with
  `ControlReply.session` — `SessionAnswer`: the matching ids, and on a hit
  the digest's own `SessionCard` (built by `LiveStateBuilder.sessionCards`,
  so the project is a folder name) plus `SessionDeepFields`. It is the
  field class the 2026-08-17 re-amendment already allows in the digest,
  over the same 0600 socket, and nothing is persisted. A named profile with
  no running engine is refused rather than answered by the focused one; an
  engine before its first scan answers no session at all (an empty index is
  not "no such session"). The listen backlog is 64 (was 4): every open
  session's status line may ask on one tick, and a full queue refuses the
  connect, which a caller can only read as "no engine". The handler still
  hops to the main actor — when the app hosts, that is its UI thread, a
  sub-millisecond lookup a few times a second. Both ends set
  `SO_NOSIGPIPE`: a client that gives up before its reply (a status line
  waits 1 s) used to make the host's late write raise SIGPIPE, which
  killed the daemon or the hosting app outright.
- `usaged` (Sources/usaged/, embedded at AgentUsage.app/Contents/MacOS/):
  RunAtLoad + KeepAlive + ThrottleInterval 10 + ProcessType Interactive
  (was Background through 0.10x — see "Under load"), signed with the app's
  identity, IOKit sleep/wake (sleep acknowledged immediately), daily
  auto-redetection. Since v0.70.0 installation is automatic (spec §10
  re-amendment 2026-08-16): core `LaunchAgentInstaller` converges the
  agent (install absent → repoint moved → bootstrap unloaded →
  upgrade an outdated plist → kickstart a daemon whose build differs from
  its binary; the decision table `ensureAction` is unit-tested, and since
  2026-11-21 it takes an intent — see "Under load") — the app runs it at every launch, the TUI spawns
  `usaged ensure` when no engine publishes, and `usaged
  install|ensure|uninstall` make the binary its own installer (the plist
  points at whichever copy ran the verb). The sticky opt-out
  `daemonAutoInstall` is set false by `usage-cli daemon uninstall` and
  the Settings toggle, and every auto-install path honors it;
  `daemon install` / the toggle re-arm it. `ensure` also self-heals: a
  plist aimed at a missing binary is rewritten (the app's own launch also
  repoints one aimed at another copy), and a live daemon running a
  different build than its binary on disk is kickstarted into it — since
  2026-11-21 by Mach-O build identity, not version, and never by
  `usaged ensure` while the lease is held ("Under load").
- Client-mode reads are read-only everywhere: digest, history.json,
  window-ledger.json, pricing cache, and transcript scans via
  `scanTranscriptsReadOnly` (parse caches never written).

## Under load (2026-11-21)

User-reported, approved as four fixes in one PR: "the initial loading time
takes ages", and "the app (and TUI) losing connection to daemon when the
machine is under heavy load". A saturated Mac is this project's normal:
about 20 coding agents at once, load averages of 200–380 on 10 cores.

- PRIORITY. Through 0.10x the plist said `ProcessType = Background`, which
  clamps EVERY thread to priority 4 — the 2 s `daemon.alive` timer, the
  publisher, the socket hop, the scans. Measured live that evening: after a
  kickstart at load 311 the heartbeat went 254 s unwritten while usaged held
  the lease, so every face called a live engine offline; the October
  incidents (a 9-minute respawn in xpcproxy, 6 minutes of silence behind a
  held lease) were the same cause. launchd.plist(5) offers four values, and
  they were MEASURED, not chosen by name: five throwaway agents
  (`io.github.avihut.usaged.loadtest-*`, scratch plists, `run-isolated`
  roots), all started at once under the same load — median 395 on 10
  cores, plus one busy loop per core — each sampled every second for 7
  minutes:

  | ProcessType | sched. priority | process start → `main()` | first publish | max heartbeat gap | socket answers |
  |---|---|---|---|---|---|
  | Background (0.10x) | 4 | 154 s | none in 7 min | 239 s | 0 of 322 |
  | Adaptive | 4 | 18.8 s | 312 s | 396 s | 0 of 322 |
  | unset = Standard | 20 | 0.6–1.2 s | 2.9–3.9 s | 3–6 s | 318 of 322, max 1.6 s |
  | Interactive | 31–37 | 0.04 s | 0.43 s | 2 s | 321 of 322, max 1.2 s |

  Adaptive follows XPC transactions, which usaged has none of, so it IS
  Background. Standard (= no key) still runs the job at 20, beneath the
  agents' 31. So: Interactive (`LaunchAgentInstaller.processType`). It runs
  the process like an app, and the heavy work inside stays at utility QoS
  (`EngineWork.heavy`: scans, cached passes, decoding, forecasts, presence
  probes, discovery) so it takes the CPU the agents leave rather than
  competing for it; the publisher and the socket answer at
  `EngineWork.responsiveQoS`. Never `.background` for the heavy work:
  background QoS is priority 4, and a scan there never finished (the 22:30
  evidence: Claude's scan running, 0.0% CPU, for minutes). A new poller in
  the engine takes its priority from `EngineWork`. ONE exception, measured:
  the cached pass that puts the previous run's activity on screen runs at
  `EngineWork.startup` (user-initiated) — bounded, once per start, and
  the step a person is waiting on. At load 294 it took 0.72 s there
  against 52.7 s at utility, in two agents started side by side.

  MEASURED AFTER (same method, the 0.10x binary beside this one, load
  median 398 plus a busy loop per core, 7 minutes):

  | build · ProcessType | → `main()` | first publish (cached meters) | activity on screen | full Claude scan | max heartbeat gap | socket answers |
  |---|---|---|---|---|---|---|
  | 0.10x · Background | not in 7 min | none | none | none | — | 0 of 417 |
  | this · Background | not in 7 min | none | none | none | — | 0 of 417 |
  | this · Interactive | 0.7 s | 1.1 s | 1.9 s (cached pass at user-initiated, load 294) | 97 s | 2 s | 415 of 417, max 0.12 s |

  The code alone does nothing for a job launchd won't run: a Background
  job didn't reach `main()` at all. The full scan still takes a minute and
  a half at that load — it re-validates 3,832 sessions at utility, beneath
  the agents, by design — but nothing waits for it any more.
- PLIST MIGRATION. `kickstart -k` does NOT pick up an edited
  `ProcessType` (checked on a throwaway label: still priority 4 after the
  edit; 31 after bootout + bootstrap), so an existing install is RELOADED.
  `ensure` compares the installed plist, parsed, with what this build would
  install FOR THAT SAME TARGET (`plistIsCurrent` — dictionaries, never
  bytes, so key order or a binary encoding can't restart a daemon on every
  launch), and only the plist's OWNER (its target is the caller's binary)
  rewrites it — two builds that disagree on the shape can never flip-flop a
  daemon. Stays inside the standing launch-agent exception (CLAUDE.md,
  user-directed 2026-08-16): same label, same agent, new content in the
  plist it already owns. The reload is `install()`'s bootout → bootstrap,
  which against a running agent hit issue #9's race (bootstrap refused
  with 5 or 37 while the old instance tears down, leaving NO daemon) — so
  `reload` now waits, bounded at 5 s of sleeps and of wall clock, for the
  service to leave the domain — whatever `bootout` answered, since a
  teardown in progress can answer non-zero — and retries 5/37 with a short
  backoff (the approach of PR #22, which retries 5; this adds 37, the
  bound and the backoff). CONVERGENCE IS JUDGED FROM LAUNCHD, NOT THE FILE:
  the plist is written before the reload, so a reload that fails leaves a
  current-looking file over an old job. `ensure` reads the loaded job's
  `program =` and `spawn type =` from `launchctl print`
  (`LaunchAgentInstaller.LoadedJob`) and the owner reloads when either
  differs from the plist; a kickstart is never aimed at a program launchd
  doesn't run (it re-runs the LOADED one, and would never converge). The
  print format is "NOT API": a field that can't be read is unknown, never a
  reason to act. The Settings toggle runs `ensure` off the main actor — a
  reload can wait seconds. usaged handles no SIGTERM, so a bootout kills it
  without it needing CPU: a starved daemon tears down in time.
- WHO MAY RUN `ensure` — an intent (`EnsureIntent`), because two rules
  collide at app launch: restarting a stale daemon means acting while it
  holds the lease, and a face that sees "offline" must never act on a live
  one. `.claim` is the app's own launch and the Settings toggle — the
  person started THIS copy: it installs, repoints to itself (issue #9
  expects `mise run app` from a second checkout to repoint), upgrades the
  plist, restarts a stale daemon. `.heal` is `usaged ensure`, which the TUI
  spawns when it finds no engine: it does nothing while ANY process holds
  the lease (`hostAlive`), and repoints only a plist whose target is
  MISSING — an existing target is the person's choice, a Spotlight hit is
  not (2026-10-04: the TUI, misreading a starved daemon as dead, repointed
  the agent at a stale worktree's bundle). The explicit verbs (`usaged
  install`, `usage-cli daemon install`) always repoint and re-arm. The
  app's launch logs the outcome instead of dropping it.
- BUILD IDENTITY. A same-version rebuild used to leave the OLD daemon
  running (the kickstart rule compared versions only), and the new app's
  client-mode scans then re-parsed everything the old daemon's cache
  lacked, every minute. Now usaged writes `{pid, version, build}` INTO
  `daemon.alive` (`DaemonMarker`, from first breath, atomic; the app still
  reads only the mtime), `build` being the Mach-O `LC_UUID` of the image it
  runs (`BuildIdentity.running()`, from memory — immune to the file being
  replaced under it). `ensure` reads the `LC_UUID` of the plist's target
  file (thin or universal) and kickstarts when they differ — but only when
  the marker's pid is the pid launchd runs NOW (a daemon just kicked and
  still starved hasn't rewritten its marker, and kicking it again would
  never end), and never on an unknown (nil) build. Same file, same UUID: an
  app launch with nothing rebuilt restarts nothing. A pre-marker daemon
  (empty file) falls back to the version rule.
- A FAST FIRST START. Stage timings now log on stderr as `startup +Nms
  <stage>` (`StartupTrace`, relative to the kernel's process start, so
  pre-`main()` time is in the first line): main, migrations, lease,
  previous digest, services, presence, probe, engines, socket, first
  publish, then per engine its meters, cached activity, scan and
  forecast, and `complete` once every engine has all of them. Measured on
  the real data size (Claude's parse cache 18.5 MB, 3,832 sessions; Codex
  1,528), the order was right but two things published nothing useful:
  the FIRST engine's launch poll left it a loading shell until the
  network answered (staggered engines already showed their cached
  snapshot), and every account's activity was zero until its full scan
  landed — 97–111 s at load 395. Now: (1) every engine presents its cached
  snapshot BEFORE its launch poll, stamped with its real `fetchedAt`;
  (2) every engine runs a CACHED PASS first (`LocalActivitySource.
  cachedScan`: the last complete scan as its parse cache saved it — no
  stat, no parse, no write — dated by the cache file's mtime, "today"
  recomputed against now), then the full re-validation; (3) the host folds
  each new engine's initial section into its first digest instead of
  waiting for a landing point. `sessionsIndexed` stays false until a real
  scan, so the socket's `session` verb never answers from carried data.
  Nothing waits on a floor it doesn't need: the stagger delays only the
  first POLL (cached meters render meanwhile); the first scan is
  immediate.
- ABSENT, NEVER ZERO (observed live 2026-11-21, 22:30: Claude's and Codex's
  activity published as `todayTokens 0 · 0 sessions` for 4+ minutes). The
  digest's additive `activityStatus {state: scanning|cached|scanned,
  asOf}` rides the top level and every profile section. A section still
  `scanning` carries `activity`, `models` and `sessions` as nil. The TOP
  LEVEL keeps its empty rollup, because every pre-0.10x decoder requires
  the field; a reader that knows the marker draws "scanning…" from it.
  `cached` is the previous run's scan, `asOf` its real age. The
  `allAgents` section (#43) reads the same status: a member whose activity
  is `cached` or `scanned` is COUNTED (its numbers are already on screen,
  dated), one still `scanning` is named and left out (`partial`), and an
  engine without the marker keeps the index rule. An unknown
  state from a newer writer reads as `scanned` in both decoders (never a
  failed decode of the whole digest). The CLI answers exit 28 for every
  reading of an unscanned account's activity — `activity`, `cost`,
  `models`, `model`, `sessions`, `session` (unless `--all`), `account`'s
  token fields and `get activity.*` — since the top level's empty rollup
  and the presence card's timeline totals would print as 0. The app's
  client-mode cached pass runs at `EngineWork.startup`, like the engine's.
  Cached LIMITS, by contrast, show as live until the launch poll replaces
  them (seconds; staggered engines did this before): a window that reset
  since they were fetched shows its old percent meanwhile, as it does
  between polls, under the real "Updated" stamp.
- BUSY, NOT OFFLINE. `EngineHostBroker.liveness` (and the TUI's
  `state::liveness`, the same rule over the same vectors in
  `Tests/UsageCoreTests/Fixtures/liveness-cases.json`): inside the
  heartbeat cutoff — max(2 × the digest's poll horizon, 180 s), unchanged —
  `live`; past it (or before a first digest) with the lease HELD, `busy`;
  with the lease free, `offline`. The lease probe is a SHARED,
  non-blocking `flock` on a read-only descriptor, taken only past the
  cutoff: it fails only against the holder's exclusive lock, so the app and
  a TUI probing at once never mistake each other for a host (the old
  exclusive trial could) — and unlike a socket connect it puts nothing in a
  starved daemon's backlog. The app's panel says "Engine busy —
  updating…" in place of the countdown, its stamp keeping the real age;
  the TUI's header says "engine busy — updating… · last update 4m ago";
  meters stay drawn, not greyed. Offline keeps its old meaning and its old
  responses (the app takes over hosting; the TUI's install nudge).
- THE OCTOBER LEFTOVERS. `ProcessSignals.ignoreBrokenPipes()` —
  `signal(SIGPIPE, SIG_IGN)` — first thing in usaged and the app (not the
  CLI, which should die quietly under `| head`): `SO_NOSIGPIPE` on the
  control socket hadn't stopped the deaths, whose source was never found.
  Both write stderr with the throwing `write(contentsOf:)`, so EPIPE is an
  error to drop rather than an exception. The control socket's server sets
  `SO_RCVTIMEO`/`SO_SNDTIMEO` (2 s) on every connection, so a client that
  connects and never sends — or stops reading — no longer wedges the serial
  accept loop. Every command is answered, even one whose caller may have
  left: a peek can't tell a vanished caller from one that half-closed after
  sending (`printf … | nc -U` does), and a write to the vanished one is
  EPIPE, not death. The client distinguishes `notListening` from `noAnswer`
  (`ControlSocket.exchange`): a host that took the connection is alive and
  late. A FULL accept queue refuses a connect with the same ECONNREFUSED as
  a stale socket file, so a refused connect with the lease beside the
  socket held is `noAnswer` too. An engine still on its first scan answers
  a `session` question with `indexing: true` (additive on the reply): busy,
  not silence. `usage-cli session` therefore never falls back to a full
  transcript scan for an engine that answered late or is still indexing —
  exit 27, "the engine is busy" — because that scan, once per status line
  per tick, duplicates the engine's own and is exactly the load that made
  it late. `usage-cli daemon status` says "busy" too. The lease's own
  acquire retries twice (2 ms) on EWOULDBLOCK, so a prober's momentary
  shared lock never reads as a taken lease.
- REPRODUCING IT without the live install: `usaged run-isolated --root
  <dir> [--bundle-id <id>] [--socket <short path>] [--copy-profiles]` runs
  the engine exactly as launchd does, under its own bundle id, storage
  roots and defaults suite, with NEITHER migration, OFFLINE usage services
  (no credential read, no request — never a second poller of the person's
  account), no status poller and no update checker; agent homes are read
  read-only as always. Copy the live support and caches trees into
  `<dir>` for a warm start. Load it under launchd with a throwaway label
  and a plist outside `~/Library/LaunchAgents` to compare `ProcessType`s;
  never the real label.

## Spec §10 amendment

IN FORCE since v0.66.0 — the authoritative text lives in docs/SPEC.md §10
("Engine host + consumer interfaces", 2026-08-16): one engine-state
artifact (`live-state.json`), one control socket + the two arbitration
artifacts, exactly one launch agent under all §10 rules, and the
lease-holder-is-sole-writer rule. Re-amended the same day at v0.70.0
(user-directed): the launch agent auto-installs from the UI entry points,
with `daemonAutoInstall` as the sticky opt-out.
