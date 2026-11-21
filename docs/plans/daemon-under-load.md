# Plan: the daemon under load, and a fast first start

Branch `fix/daemon-under-load` (base 88c5e9f), one PR (user-approved 2026-11-21: all four fixes
together). Brief: the coordinator's `briefs/daemon-under-load.md`, plus the lead's
22:30 addendum (an account whose first scan hasn't landed publishes its activity as
ABSENT, and the previous run's activity is published at once with its real age).

Status: BUILT (approved as written 2026-11-21). This file is the plan as approved;
where the build departed from it, a note says so inline ("Built:"). The measured
results and the final rules live in `docs/DAEMON.md` "Under load".

## What the code does today (read 2026-11-21)

- **Plist** (`LaunchAgentInstaller.plistData`): `ProcessType = Background`, which
  is priority 4 for every thread, including the main thread that runs the 2 s
  `daemon.alive` timer, the publisher and the socket hop. launchd.plist(5) gives
  four values. No value at all means "light resource limits, throttling CPU and
  I/O". Standard is the same as no value. Adaptive moves between Background and
  Interactive on XPC transactions, which usaged has none of, so it behaves as
  Background. Interactive means "the same limits as apps, that is to say, none".
- **`ensure`** rewrites the plist only when the target path differs. It kickstarts
  only when the digest's `appVersion` differs from the caller's version. It never
  compares plist content. `install()` runs `bootout` and then `bootstrap`
  immediately, which is the race in issue #9 (bootstrap fails with 5 or 37, and the
  agent is left unloaded).
- **Startup** (`Usaged.main` → `DaemonHost.start` → `MeteringHost.start`):
  1. IdentityMigration and StorageMigration (marker-checked).
  2. Write the marker, then try the lease every 2 s. While the app hosts, the app
     notices the marker only on its 30 s role check.
  3. On main: decode the previous digest, run `probeSynchronously` (session-file
     walks for every enrolled account), and init each engine (`history.load`, about
     1.3 MB of JSON for Claude, and the ledger).
  4. Each engine's launch poll. Polls are staggered across the 180 s floor for
     networked engines.
  5. Bind the socket and publish.
- **First publishes are empty.** Several gaps produce them:
  - The first engine (delay 0) is `isRefreshing` during its launch poll, so its
    cached snapshot is skipped and the state is `.loading` until the network
    returns.
  - Activity, sessions and models are `[]` until the first full scan lands, and
    that scan re-parses every changed transcript (Claude's cache is 18.5 MB).
  - The host's `republish()` at the end of `start()` has no sections yet.
  - Today at 22:30 this published `todayTokens 0 · 0 sessions` for more than 4
    minutes.
- **Faces.**
  - The TUI calls the engine offline past `max(2 × horizon, 180 s)`. On offline at
    startup it runs `usaged ensure` from `find_usaged`, which can be Spotlight's
    first hit (the 2026-10-04 repoint).
  - The app in client mode never says anything. Past the cutoff it takes over only
    if the lease is free. Otherwise it keeps rendering old numbers with no word
    about it.
- **Socket.**
  - The server's accept loop is serial. `serve()` reads with no timeout, so one
    silent client wedges every later connection. It blocks on a semaphore until the
    main-actor handler answers.
  - The client returns nil for both "nobody listening" and "no answer in 3 s".
  - `usage-cli session`'s 1 s engine lookup treats a late answer as a miss and
    falls back to a full transcript scan. A busy daemon therefore multiplies its own
    load through every status line.
- **SIGPIPE.** `SO_NOSIGPIPE` is set on control-socket descriptors only. No
  process-wide `SIG_IGN`. The 2026-10-29 death has no known source.

## Phase 0: measure before touching anything

### 0.1 An isolated dev usaged (a hatch)

`usaged run-isolated --root <dir> [--bundle-id <id>]`. It is a verb, so launchd's
no-argument spelling is untouched. It branches before both migrations, which run
against standard roots, and with a fresh suite IdentityMigration would be pending
again.

- **Identity.** Its own bundle id (default `io.github.avihut.AgentUsage.isolated`),
  so the digest, lease, socket and marker live under `<dir>`, never the live
  bundle root. Its own defaults suite of that id, deleted afterwards.
- **Roots.** `StorageScope.Roots(support: <dir>/support, caches: <dir>/caches)`.
- **No credential, no network poll.** `MeteringHost`'s `serviceFactory` returns a
  `UsageService` over a stub provider client that serves the account's cached body.
  Setup copies the cached bodies; it reads the live caches and never writes them.
  No Keychain read, and no second poller against the person's account.
- **No status poller, no update checker** (`pollsStatus: false`, feed nil).
- **Copied profile records.** It meters the same homes as the live daemon: the
  account records are copied read-only from the live defaults into the isolated
  suite.
- **Agent homes** are read exactly as the scanners read them: read-only.
- **Scan caches.** Two modes:
  - Warm (the person's restart): copy the live `activity-cache.json`,
    `history.json` and ledgers into `<dir>`.
  - Cold: empty roots.
- The hatch becomes the permanent repro and stays documented in DAEMON.md.
- **Network stage.** It is timed without a second poller. The credential spawn and
  HTTP time are read from the trace of the one real poll the LIVE daemon makes
  anyway (a stage line after this ships). Before that, they are read from a single
  `mise run cli` fetch, once idle and once loaded: one request, far inside the
  budget.

### 0.2 Startup trace (stays in the product)

`StartupTrace` (core) logs one line per stage, relative to `main()`:
- migrations;
- providers;
- lease acquired;
- presence and probe;
- each engine created;
- first publish;
- each engine's first meters (cache or network) and first scan landed (with file
  counts: parsed vs cache hits);
- predictions;
- **complete**: every running engine has meters, a landed scan and predictions.

It logs on stderr, the daemon's existing log path. The time from launchd's spawn to
`main()` is pre-main (October's 9 minutes in xpcproxy), so it is read from
`/usr/bin/log show` (launchd's spawn line vs the first trace line).

### 0.3 Load and priority experiment

- **Load generator.** A scratch C or shell spinner, one busy loop per core (10), at
  normal priority. Bounded: each run kills itself after N minutes, about 15 minutes
  in total.
- **Variants.** Background, Standard, Interactive, and Adaptive (for the record).
  Each is a THROWAWAY launch agent (`io.github.avihut.usaged.loadtest-<variant>`).
  The plist is bootstrapped from the scratchpad, never `~/Library/LaunchAgents`.
  No KeepAlive, StandardErrorPath in the scratchpad, `run-isolated` with its own
  root. Each is booted out and deleted afterwards. All variants run AT THE SAME
  TIME, so they see the same load. If the permission layer refuses a bootstrap, I
  report that and fall back to `taskpolicy` clamps (`-b`, `-c utility`), labelled
  as such. I don't route around a refusal.
- **Sampler.** Every 1 s it records each variant's `daemon.alive` and digest
  mtimes, a socket `status` round trip (connect → reply), and `ps -o pri`.
- **Per variant:** spawn → `main()`, the max heartbeat gap, the max socket latency,
  time to first publish, time to first COMPLETE publish, and the scan's completion
  time.
- **Checks along the way:**
  - whether `kickstart -k` picks up an edited `ProcessType`. I expect it doesn't:
    launchd reads the plist at bootstrap;
  - the effective thread priorities of utility- vs background-QoS work inside a
    Standard or Interactive job.

### 0.4 Cold and warm start on the real data size, unloaded and loaded

The stage table from 0.2, before and after. It covers decoding the 18.5 MB cache
alone, against reading the previous digest, which `startHost()` already decodes.

## Fix 1: daemon priority

- **ProcessType.** The best measured of Standard and Interactive. I expect Standard
  to suffice, since the main thread then competes at about 31 like the person's
  agents rather than 4. If Standard still shows multi-second heartbeat gaps at
  load 300, it is Interactive, which the man page reserves for exactly "an app's
  ability to be responsive depends on it". The numbers go in DAEMON.md.
- **Heavy work at lower QoS.**
  - One named constant: `EngineWork.heavy` (a `TaskPriority`, plus a matching
    `DispatchQoS`) replaces the scattered `.utility` literals at every heavy
    off-main hop: scans, predictions, reprobe, discovery, and the new cached-activity
    pass. The Antigravity quota poller on `fix/antigravity-zero-setup` inherits it
    by using the constant.
  - It stays at UTILITY, not background. Background-QoS threads run at priority 4,
    and that is precisely what starved today's scan (the lead's 22:30 evidence).
    Phase 0 measures it.
  - The publisher's queue and the socket's accept queue move UP (`.userInitiated`):
    they are the responsiveness path, and they are tiny.
  - The main-thread work at startup is audited from the trace. `probeSynchronously`
    and the engines' history decode move off main if the trace shows them costing
    the first publish.
- **Plist migration for existing installs.**
  - `ensureAction` gains a `plistCurrent` input. The installed plist is parsed and
    compared as a dictionary against `plistDictionary(binary: installedTarget)`,
    never as bytes, and never against the caller's binary: that would be a repoint
    through the back door.
  - It is rewritten only by the bundle that OWNS the target (target == the
    caller's binary), so two builds with different plist shapes can never flip-flop
    a daemon.
  - It is applied with the reload that `ProcessType` needs (bootout → bootstrap),
    so this PR fixes issue #9's race, which every existing install would otherwise
    walk into. After `bootout`, `install()` waits, bounded to a few seconds, for
    `launchctl print` to stop finding the service, then bootstraps, retrying on 5
    and 37 with a short backoff. The failure carries launchctl's text.
  - The sticky `daemonAutoInstall` opt-out still wins every row.
  - This stays inside the standing launch-agent exception (CLAUDE.md,
    user-directed 2026-08-16, v0.70.0): the same label, the same agent, and new
    content in the plist it already owns. The PR says so.

## Fix 2: a fast first start

**Publish what's known at once, marked with its real age.**

- **Meters.** Every engine, including the delay-0 one, presents its cached snapshot
  BEFORE its launch poll goes out. The snapshot's `fetchedAt` is its real age.
  This is today's staggered-engine precedent, extended to the first engine. It also
  means the launch poll's `previous` is that snapshot, exactly as for staggered
  engines.
- **Activity, the lead's (b).** A new `LocalActivitySource.cachedScan(now:)`,
  defaulting to nil, implemented by the Claude, Codex and Antigravity sources. It
  decodes `activity-cache.json` and aggregates its entries AS SAVED: no stat, no
  parse, no write. Its as-of is the cache file's mtime, which is when the last
  complete scan saved it. The rollup is rebuilt against `now`, so "today" is never
  carried across a local-day boundary.
- **Ordering.** (Built: at `EngineWork.startup`, user-initiated — at utility the
  pass took 52.7 s under load, 0.72 s at user-initiated.) The engine runs it before the full scan, and lands it
  only if the full scan hasn't landed yet. `sessionsIndexed` stays false until a
  real scan, so the socket's `session` verb never answers from carried data.
- **Speed.** If Phase 0 shows the 18.5 MB decode itself slow under load, the
  previous digest's own section (already decoded at `startHost`, same local day,
  and only when it carries the as-of stamp below) is the instant tier in front of
  it. The plan's default is the cache pass alone; the numbers decide. (Built: the
  cache pass alone — under load it lands in about 2 s, so no instant tier.)
- **Order.** The host publishes once, right after the engines exist (cached meters
  plus cached-or-absent activity), coalescing the N engines' init publishes. The
  network poll and the heavy scan follow. The bar's numbers come first.
- **The client-mode app.** It draws activity from its own read-only scan
  (`DigestClient`), so it gets the same cache pass first, and it renders "scanning…"
  until either lands.

**Absent, never zero (the lead's (a)).**

- An additive digest field, `activityStatus: { state: "scanning" | "cached" |
  "scanned", asOf: Date? }`. It sits on the top level and on every profile section.
- A section whose engine has neither a cached pass nor a landed scan publishes
  `activity`, `models` and `sessions` as nil. Those fields are already optional in
  `ProfileState` and Rust's `ProfileSection`.
- The TOP-LEVEL `activity` is non-optional in both decoders. Omitting it would break
  every pre-PR app and TUI, so the top level keeps the empty rollup for old readers
  and carries `activityStatus = scanning`. New readers draw "scanning…" from the
  marker, never the zeros.
- An absent field means an old writer, and readers behave as today.
- Goldens are regenerated with `UPDATE_GOLDENS=1 swift test --filter LiveState`, and
  the diff is read. The freeze test against main's goldens stays green (additive
  only).
- **Faces.**
  - The TUI's activity, MODELS and sessions panes say "scanning…" while scanning,
    and add a dim "as of 22:15" while cached.
  - The app's panel says the same in its activity and sessions sections. Since
    #37 its Activity reading totals every agent (`ProviderRegistry+Consumption`).
    An account still scanning is therefore named in that reading ("Claude:
    scanning…") and left out of the total, never added as zero, so a partial total
    can't pass for a whole one.
  - The bar is unaffected, since it shows meters only.

**Nothing waits on a floor it doesn't need.** Each wait is audited from the trace:

- The stagger delays only the first POLL. Cached meters now render meanwhile.
- The gate seed.
- The first scan is immediate.
- The lease wait while the app hosts is up to 30 s plus the app's shutdown. If the
  trace shows it, a hosting app checks the marker every 5 s (one `stat`) instead of
  every 30 s.

**The build-identity kickstart.**

- The identity is the binary's own Mach-O `LC_UUID`. The running daemon reads it
  from its in-memory image (`_dyld_get_image_header(0)`). `ensure` reads it from
  the target file, handling thin and fat binaries and picking the running arch's
  slice. That is the binary's identity, with no bundle-script stamp to keep in
  step: bundle.sh and dist.sh can't drift.
- The daemon announces `{pid, version, build}` as the CONTENT of `daemon.alive`. It
  is written from first breath (before the lease), with the same 2 s cadence and an
  atomic write. The app reads only its mtime, as today.
- `ensure` kickstarts only when all of these hold:
  - the agent is loaded;
  - launchd's running pid equals the marker's pid (a just-kickstarted, still-starved
    daemon is never kicked again);
  - the marker's build is non-nil and differs from the target file's build.
- A nil identity on either side is never a mismatch. A marker from a pre-PR daemon
  (empty content) falls back to today's version rule.
- With the same file, it is the same UUID, so an app launch with nothing rebuilt
  never kickstarts.

## Fix 3: "busy", not "offline"

- **One pure rule, the same test vectors on both sides.**
  - Swift: `EngineHostBroker.liveness(generatedAt:nextPollAt:now:leaseHeld:)`.
  - Rust: `freshness(now, lease_held)`.
  - Within the cutoff: Live, Stale or Backoff, as today.
  - Past the cutoff with the lease held: **Busy**.
  - Past the cutoff with the lease free, or no digest: **Offline**.
  - The cutoff is unchanged: `max(2 × horizon, 180 s)`.
  - The vectors live in one fixture that both test suites decode. (Built:
    `Tests/UsageCoreTests/Fixtures/liveness-cases.json` — outside `digest/`,
    whose every file the Rust suite decodes as a digest.)
- **The probe.**
  - The lease, not the socket: a connect probe would fill a starved daemon's
    backlog.
  - A SHARED non-blocking `flock` (`LOCK_SH|LOCK_NB`). It fails only against a real
    exclusive holder, so two probers never see each other as "held". Today's
    exclusive trial in `EngineLease.isHeld` is switched to it, with the same answer
    for the app's takeover rule.
  - Rust: std's `File::try_lock_shared`, stable since 1.89 (the TUI is on 1.95). No
    crate.
  - It is probed only past the stale cutoff.
- **The app.**
  - The registry exposes `engineLiveness`. In client mode, past the cutoff with the
    lease held, the panel's status row reads "Engine busy — updating…" in place of
    the countdown. "Updated <stamp>" keeps the real age.
  - The bar keeps its numbers. Busy is not an error, so there is no grey.
  - Offline stays what it is: the app takes over hosting.
- **The TUI.** The header reads "engine busy — updating… (last update 4m ago)",
  with meters drawn normally. The "engine offline — start: usage-cli daemon start"
  text is kept for a truly dead or absent host.
- **Who may run `ensure`, and what it may do.** An intent input to `ensureAction`:
  - **`.claim`**: the app's own launch-time converge. It may install, repoint to
    itself, upgrade plist content, bootstrap, and kickstart on a build or version
    mismatch. Issue #9 expects exactly this: "`mise run app` from a second checkout
    repoints the agent and leaves it running".
  - **`.heal`**: the reactive path (`usaged ensure`, which the TUI spawns when it
    sees Offline). It NEVER acts while the lease is held (a live host), and repoints
    ONLY when the installed target is missing. That is October's proposed guard,
    kept for the path where it was the right one: the 2026-10-04 TUI hijack came
    through here.
  - **Explicit verbs** (`usaged install`, `usage-cli daemon install`, the Settings
    toggle) stay explicit: they always repoint and re-arm.
- **The TUI** runs its nudge only on Offline, never on Busy.

## Fix 4: the October leftovers

- **`signal(SIGPIPE, SIG_IGN)`** first thing in `Usaged.main()` and in the app's
  entry point. Not in `usage-cli`: a CLI piped into `head` should die quietly, which
  is Unix's default. The daemon's and the app's stderr logging moves to the throwing
  `write(contentsOf:)`, so EPIPE on a closed stderr is an ignored error, not an
  ObjC exception.
- **Server timeouts.**
  - On each accepted connection: `SO_RCVTIMEO` (2 s, since the request line follows
    connect at once) and `SO_SNDTIMEO` (2 s), so a silent or vanished client costs
    the serial loop at most that.
  - A read-only verb (`status`, `session`) whose client has already hung up is
    skipped, checked with a `MSG_PEEK|MSG_DONTWAIT` EOF test before the main-actor
    hop. Nobody reads the answer.
  - A mutating verb still runs: the person asked for it.
  - (Built, then REMOVED: the peek reads EOF for a client that half-closed after
    sending and still waits — `printf … | nc -U` got no reply in a live check. Every
    command is answered; a write to a vanished client is EPIPE, ignored.)
- **Client result.**
  - `ControlSocket.exchange` returns reply, `notListening` or `noAnswer` (connected,
    late). `send` keeps its nil-returning shape for current callers.
  - The app's fire-and-forget sends get a longer timeout (nothing waits on them).
  - **`usage-cli session`: a late answer is not a miss.** On `noAnswer` the
    shortlist miss does NOT fall back to a full transcript scan. It answers like a
    busy scan lock (the CLI.md exit code for "engine busy"; CLI.md is checked
    first). That is the documented intent ("a host too busy to answer in a second
    costs that line its number, never a stall"), and it stops a busy daemon
    multiplying its own load.
  - The TUI already distinguishes `NoAnswer`. Its echo says "the engine is busy —
    it will act on it" instead of "didn't answer".

## Tests (everything the gate can hold)

- **`LaunchAgentInstallerTests`.**
  - The plist dictionary (`ProcessType` value, keys).
  - `plistCurrent`: equal dictionaries in a different byte order are current; a
    Background plist is not.
  - Owner-only rewrite.
  - `ensureAction` rows for `.claim` and `.heal`: lease held → nothing; target
    missing → repoint; target elsewhere → heal leaves it, claim repoints.
  - The build rule: pid mismatch → nothing; nil build → nothing; same build →
    healthy; differing build → kickstart; version-rule fallback.
  - The #9 race through the `CommandRunner` seam: the first bootstrap returns 37
    and the second 0 → `.installed`; never-recovering → `.failed` with launchctl's
    text, inside the budget.
- **`BuildIdentity`.**
  - Parser on synthetic thin and fat headers, including a fat file with no slice for
    the arch → nil.
  - `running()` equals `of(binary:)` of the test process's own executable.
- **The `DaemonMarker` round trip**, plus tolerance of an empty (pre-PR) and a torn
  file.
- **Liveness.** The shared case fixture, in Swift and in Rust (cargo).
- **The shared-lock probe.** An exclusive holder → held. A free lease → not held.
  Two probers → neither held.
- **Socket.**
  - A connected-but-silent client doesn't wedge the server: a second client is
    answered inside the timeout.
  - A slow handler → the client gets `noAnswer`, not `notListening`.
  - A hung-up read-only client → the handler is not called.
  - SIGPIPE ignored: a write to a closed peer returns EPIPE in-process.
- **Engine / host.**
  - The first publish carries cached meters for a delay-0 engine.
  - The cached activity pass lands as `cached` with the cache's mtime and is
    replaced by the scan. It is never applied after a scan.
  - A host with no cache publishes the section's activity, models and sessions as
    nil with `scanning`.
  - "Today" across a day boundary is recomputed.
  - `sessionsIndexed` is false after only the cached pass.
- **Digest.** Goldens regenerated with the new field; Rust decodes them; the freeze
  test is green against main.
- **CLI.** A session lookup with `noAnswer` doesn't scan.

## Verification (the live install stays untouched)

- **The Phase 0 table, before and after.** Per variant: the heartbeat gap, socket
  latency, spawn → `main()`, time to first and complete publish, and scan
  completion, at load. Also the cold and warm stage timings on the real data size.
- **Snapshots.**
  - `--snapshot` with `--demo-digest`: the app's busy state (via a hatch flag that
    forces liveness in a demo, since a fixed feed has no lease) and the "scanning…"
    and "cached as of" activity states. Each comes from a synthetic digest.
  - The TUI's busy, scanning and cached renders, via `--digest` against synthetic
    digests.
- **`mise run gate`** green before every report.
- **Never:** `mise run app` or `hatch`, launching a dev build normally, `ensure` or
  `install` from a dev build, or `launchctl` on `io.github.avihut.usaged`.

## Docs

- **DAEMON.md:** priority and the measured table, the lifecycle with startup
  stages, the `daemon.alive` content, the build-identity kickstart, the busy state,
  claim vs heal, the socket timeouts, and the `run-isolated` hatch.
- **ARCHITECTURE.md:** the startup order and publishing what's known first.
- **UI.md:** the busy row and the "scanning…" and "cached" activity states.
- **TUI.md and TUI-PARITY.md:** Busy, and the scanning and cached panes.
- **CLI.md:** the session lookup on a busy engine.
- **CLAUDE.md never-again:** "A launch agent at `ProcessType = Background` starves
  under load: the heartbeat stops while it holds the lease" (once measured).
- **`.release-notes/next.md`:** Fixes entries, appended; the first line is never
  touched.

## Assumed (decisions taken without the person; each goes in the PR body)

1. **The fix-2/fix-3 collision.** The build-identity kickstart needs `ensure` to act
   while a daemon holds the lease, and the brief says no face may. It is resolved
   by intent:
   - The app's own launch (`.claim`) may repoint and kickstart: issue #9 expects
     `mise run app` from another checkout to repoint, and "a moved bundle is
     repointed" is documented behavior.
   - The reactive heal (the TUI's nudge, `usaged ensure`) never acts while the lease
     is held, and repoints only a missing target.
2. **Issue #9's race is fixed here,** because the plist migration reloads every
   existing install through `install()`. Without it, the upgrade would leave
   installs with no daemon. This overlaps the outside contributor's open PR #22,
   which handles 5 only. It is credited in the PR, and I rebase onto #22 if the
   person merges it first.
3. **The build identity is `LC_UUID`,** carried in `daemon.alive`'s content, rather
   than a bundle-time stamp or a new digest field.
4. **The top-level digest keeps the empty rollup** for old readers, beside the
   additive `activityStatus`. Removing it would break every pre-PR decoder.
5. **Busy doesn't grey the bar.** It is a sentence in the panel and the TUI header.
6. **Heavy work stays at utility QoS, not background** (background = priority 4).
7. **`usage-cli` does not ignore SIGPIPE.**
8. **The dev hatch never polls the real endpoint** (stub service). The network
   stage is timed from the live daemon's own trace or a single `mise run cli`.

## Found (belongs in other branches; not fixed here)

- The client-mode app re-parses every changed transcript in full every 60 s, since
  a cache hit needs an exact mtime and size match. That is load the app adds on a
  20-agent machine (October's research; issue #24 family).
- `live-state.json.sb-*` temp leftovers in the bundle root, dated Oct 5 and Nov 15.
- usaged's stderr goes to /dev/null under launchd, so every `[usaged]` line,
  including the new startup trace, is invisible in production. Unified logging
  would fix it; it needs a privacy read of what the lines carry.
- The TUI's `find_usaged` could prefer the installed plist's own target before
  Spotlight.

## Overlap

- **`fix/antigravity-zero-setup`** adds an Antigravity quota poller in the engine.
  It should take its QoS from `EngineWork.heavy`, and its launch publish follows
  "cached first".
- **PR #22** (open since 2026-10-03, an outside contributor, "Closes #9") retries
  bootstrap on status 5 after waiting for the bootout. Fix 1 needs that race fixed,
  and launchd's own log later showed 37 as well, so this branch carries the fix,
  covering 5 and 37, in the same shape and credited to #22. If the person merges
  #22 first, I rebase onto it and keep only the 37 retry and the migration.
- **#37** (one Activity reading across every agent) MERGED after this branch was
  cut. The branch is fast-forwarded to 88c5e9f, so the plan is against the merged
  panel.
