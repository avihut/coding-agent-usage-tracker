# Antigravity limits with zero setup — plan

Branch `fix/antigravity-zero-setup`, cut from main at 542aa67. Follows
`docs/plans/antigravity.md` (PR #36, merged as f8ceaae, in no release yet).

> **The person's direction (2026-11-21, user-directed):** "There shouldn't
> even be a path that requires extra work from the user to start metering
> antigravity." This authorizes the spec §10 amendment a zero-setup route
> through the vendor's own documented client needs.

## Decision record

| Topic | Decision |
| --- | --- |
| Route | The engine host spawns the vendor's own documented print mode: `agy -p /quota --output-format json --log-file /dev/null`, with `AGY_CLI_DISABLE_AUTO_UPDATE=true` and cwd `/`. Nothing to set up |
| Where it runs | Only inside an engine the lease holder runs (usaged, or the app while it hosts). The runner is opt-in per host: tests, `--snapshot`, `usage-cli` and a client-mode app never get one |
| When | Only when a conversation was written since the last reading started (the first reading: a conversation written in the last 7 days). Floor 10 min, measured from the last ATTEMPT and persisted, so restarts, handovers and manual refreshes can't beat it. One run at a time. 30 s hard timeout that kills the process group. Backoff 20 → 40 → 80 → 120 min after failures |
| What is kept | Bucket id, remaining fraction and absolute reset only, in `<bundle>/antigravity/default/quota-probe.json` (mode 0600, written by the engine, which is the single writer) |
| Status line | REMOVED: `usage-cli export-statusline`, `UsageProvider.statusLineExport`, `StatusLineExport`, the single-writer carve-out and every "paste this" string (see "The status line" below) |
| Meters | Gemini only (ADDED SCOPE, the person ~22:55: "Could you remove them from that harness? They're just polluting the status and I'm not actually using them"): `gemini-5h` → Session (5h), `gemini-weekly` → Weekly, labels and ids unchanged. The Claude + GPT pool (`3p-5h`, `3p-weekly`, bar tag C) is skipped like `gemini-argon-wtu-weekly` and every model-specific bucket |
| Models and prices | Gemini only (ADDED SCOPE 2, ~23:10): `pricingSelector` = Gemini's feed slice alone, `modelCatalog` = Gemini's grammar alone. A non-Gemini model that does appear in a transcript still counts in tokens, and its cost reads unpriced (null, "—", never $0) |
| Model scope | The two Gemini meters keep `modelScope: ["gemini"]`: Gemini's quota is spent by Gemini models only, so a stray non-Gemini call must not move their curves. `Meter.modelScope` / `LiveMeter.modelScope` and the lockout scope rule stay as generic machinery, still used; the digest is untouched |
| Failures | Never thrown from the fetch. The service turns the probe's standing outcome into `.cached(snapshot, error)`, so focus always sees a snapshot (empty or not) and the reason travels in the digest's existing error text, hint and code. A missing CLI is silent |
| Classification | `networkDestinations` stays `[]` (the app connects nowhere new; `isLocalProvider` unchanged). The by-proxy run is declared separately (`UsageProvider.quotaCommand`) and rendered on its own privacy-card lines |

## What was measured (2026-11-21, 22:33–22:47 local, read-only toward the agent home)

Method: a path/mtime/size listing (`stat`, never content) of `~/.gemini`,
`~/.antigravity`, `~/.config`, `~/.cache`, the Antigravity app's Application
Support folder and LaunchAgents, plus depth-2 listings of `~/Library/Caches`,
`Logs`, `Preferences`, `Application Support`, `HTTPStorages`, `$TMPDIR` and
`/private/tmp`. One listing before each run and one after, diffed, plus a
control pair with no run (the person's idle agy session wrote nothing in
`~/.gemini` in that window). The environment was the daemon's own (read from
the live usaged with `ps -E`, names only): `env -i HOME USER LOGNAME SHELL
TMPDIR PATH=/usr/bin:/bin:/usr/sbin:/sbin`, cwd `/`. The raw `/quota` output
went to a 0600 file in the session scratchpad and was only ever read through
a shape dumper (key paths, value types, values at allowlisted keys).

### The runs

| Run | Invocation | Wall | CPU (u+s) | Max RSS | Wrote inside `~/.gemini/antigravity-cli` |
| --- | --- | --- | --- | --- | --- |
| `--version` | — | 0.08 s | 0.10 s | 127 MB | nothing |
| `--help` | — | 0.24 s | 0.12 s | 127 MB | nothing |
| 1 | `-p /quota --output-format json` | 2.54 s | 0.43 s | 209 MB (137 MB peak footprint) | NEW `log/cli-<stamp>.log` (14 KB), `cli.log` symlink re-pointed, NEW `implicit/<id>.pb` (189 B); mtime stamps on `cache/onboarding.json`, `conversation_summaries.db`, `crashes/`, `cache/`, the home folder itself |
| 2 | + `--log-file /dev/null` + `AGY_CLI_DISABLE_AUTO_UPDATE=true` | 2.15 s | 0.48 s | 209 MB | mtime stamps only: `cache/onboarding.json`, `conversation_summaries.db`, `crashes/`, `cache/`, the home folder |
| 3 | + `--log-file /dev/null` only | 2.19 s | 0.37 s | — | same as run 2 |
| 4 | both levers, 16 m 47 s after the last update check | — | — | — | same as run 2; `last_check.timestamp` and `updater/` NOT touched |
| 5 | both levers, sockets watched with `lsof` | — | — | — | (not listed) |

- **The update check.** The CLI checks for an update at start-up behind a
  15-minute debounce (`last_check.timestamp`; its log says "Last check was
  less than 15 minutes ago, skipping update"). Runs 1–3 fell inside a check
  another caller had just made. Run 4, past the debounce, with
  `AGY_CLI_DISABLE_AUTO_UPDATE=true`, left `last_check.timestamp` and
  `updater/` alone: the variable stops the check. It is documented (the
  official troubleshooting page: "Set the `AGY_CLI_DISABLE_AUTO_UPDATE`
  environment variable to `true`"), and Homebrew's own `antigravity-cli`
  cask wrapper sets exactly this variable for every run.
- **`--log-file /dev/null`** (documented in the CLI reference: "Override the
  CLI log file path") removes the new log, the `cli.log` re-point, and,
  observed, the `implicit/*.pb` as well (runs 2 and 3). That last link is an
  observation from one no-lever run against three lever runs, not a
  documented behaviour, so the amendment authorizes the SUPERSET of writes
  seen in any run.
- **What can't be turned off.** The mtime stamps on `cache/onboarding.json`,
  `conversation_summaries.db` (the CLI's summary store reconciles at every
  start: "starting background reconciliation (trigger=startup)") and the
  `crashes/` folder, plus the folder mtimes, came with every run. No sizes
  changed. No documented flag or variable covers them. `conversations/` and
  `brain/` were never touched by any run (the `conversations/` mtime stayed
  22:30:45 throughout), so a probe never wakes its own activity gate.
- **No child left behind.** The CLI spawns `/usr/bin/security` during the run
  (seen in `ps`): it reads its OWN sign-in from the login Keychain the
  promptless way, as the item's own client, which is how this app reads
  Claude Code's item. Nothing was left running after any run.
- **Credentials by proxy.** The CLI's log for run 1 shows its sign-in loaded
  from the keyring with an expiry 30 minutes out. A scheduled run will
  sometimes refresh that token and write it back to its own Keychain item
  (or, per its changelog, its file fallback inside its home). The app never
  sees, reads or stores any of it. A run across an expiry is measured below
  (see "Token refresh").
- **Network, by the vendor's process.** Run 5: 10 TCP connections, all to
  port 443, at three IPv6 addresses in Google-owned prefixes
  (`2001:4860::/32`, `2a00:1450::/32`). The CLI's own log of run 1 names
  `daily-cloudcode-pa.googleapis.com` (`v1internal:loadCodeAssist` ×4,
  `v1internal:fetchAvailableModels` ×1), its experiment-flag refresh and one
  mention of `jetski-webchannel.googleapis.com`, all under its own sign-in.
  This app opens no socket and names no Google host in its sources.
- **Spending.** None. Runs 2–5 returned bit-identical fractions and resets
  over 10 minutes with no conversation written, the result reports
  `num_turns: 0` and zero tokens, and no conversation was created.
- **Cost.** About 2.2–2.5 s wall, 0.4–0.5 s CPU and a transient 209 MB per
  run. At the floor that is at most 6 runs an hour while Antigravity is in
  use, about 3 CPU-seconds an hour, and nothing on a machine where it is
  idle or absent.

### Token refresh

Run 6, with both levers, started 23:05:50, 46 s after the expiry the CLI
had logged for its token, with `~/Library/Keychains` added to the listing
(`stat` only, never opened). It succeeded in 2.54 s with the same readings,
and changed no Keychain file and nothing new in the home: the same five
stamps as every lever run. With the log off, whether it refreshed the token
itself or loaded one the person's open session had already refreshed can't
be told apart. The amendment therefore authorizes the vendor's process to
refresh its own sign-in and write it back where it keeps it, and says the
app never sees any of it.

### The real `/quota` payload (step V0 of #36, settled)

`command.name` is `usage` (`/quota` is its alias), so the reducer keys on the
structure, never on the name. Shape, every value replaced except where safe:

```text
{ conversation_id: "", status: "SUCCESS", response: <text table>,
  duration_seconds: 0, num_turns: 0,
  usage: { input_tokens, output_tokens, thinking_tokens, cache_read_tokens, total_tokens },
  command: { name: "usage", data: { description: <text>, groups: [
    { name: "Gemini Models", description, buckets: [
        { id: "gemini-weekly", name, description, window: "weekly", remaining_fraction: 0.77, reset_time: "2026-11-28T14:02:05Z" },
        { id: "gemini-5h",     name, description, window: "5h",     remaining_fraction: 0.75, reset_time: "2026-11-22T00:02:05Z" } ] },
    { name: "Claude and GPT models", description, buckets: [
        { id: "3p-weekly", name, window: "weekly", remaining_fraction: 1, reset_time: "1970-01-01T00:00:00Z" },
        { id: "3p-5h",     name, window: "5h",     remaining_fraction: 1, reset_time: "1970-01-01T00:00:00Z" } ] },
    { name: "Gemini 4 Argon", description, buckets: [
        { id: "gemini-argon-wtu-weekly", name, description, window: "weekly", remaining_fraction: 0.98, reset_time: "…" } ] } ] } } }
```

- **Bucket ids** (owed since #36): `gemini-5h`, `gemini-weekly`, `3p-5h`,
  `3p-weekly`, and `gemini-argon-wtu-weekly` — exactly the ids the meters
  were built for, plus the Argon bucket, which stays skipped. Each bucket
  also states its `window` (`5h`, `weekly`), which agrees with the id.
- **Tier ids**: `/quota` carries no plan tier at all, and no account
  identifier (no email, no project: `conversation_id` is empty). The plan
  name for Antigravity becomes nil (the panel shows no plan line).
- **An untouched pool** reads `remaining_fraction: 1` with the Unix epoch as
  its reset. The epoch means "no window running" and is normalised to no
  reset, or the rolled-window rule would turn the meter into a dash.
- **"A reset but no fraction is spent"**: still unobserved — no spent bucket
  exists on this account today. Zero-valued resets ARE printed (the epoch),
  which says nothing about whether a zero fraction is. Kept, narrowed: it
  applies only when the bucket states a REAL reset in the future, never the
  epoch. Still marked unverified.

### Finding the binary

| Location | What it is | Probed? |
| --- | --- | --- |
| `~/.local/bin/agy` | the install script's documented default ("Default binary location: `~/.local/bin/agy`"); this Mac's, 229 MB | yes |
| `$HOMEBREW_PREFIX/bin/agy` — `/opt/homebrew/bin/agy`, `/usr/local/bin/agy` | the `antigravity-cli` cask's `command_wrapper`, a script that execs the Caskroom binary with `AGY_CLI_DISABLE_AUTO_UPDATE=true` | yes |
| `~/.antigravity/antigravity/bin/agy` | the DESKTOP app's editor launcher, a symlink into `Antigravity.app` (#36's investigation; its `--version` is the editor's 1.107.0) | **no** — the brief listed it; running it with `-p /quota` would start the editor, not the agent |

The installer documents no flag or variable that moves the binary. Each
candidate is used only when it resolves (symlinks followed) to an
executable regular file outside any `.app` bundle, and its `--version`
prints one bare version line (measured: 0.08 s, writes nothing). That is
checked once per file identity (path, size, mtime) and remembered in the
probe's state file. Nothing is looked up on `PATH`: the daemon's `PATH` is
`/usr/bin:/bin:/usr/sbin:/sbin`, and asking a login shell would run the
person's shell profile.

### The other caller

The `agy -p "/quota"` runs every ~13 minutes during #36 came from the
person's other project's coordinator script,
`~/Projects/shoe-usage-tracker/.coordinator-scripts/newagy.sh`, which gates
every Antigravity worker launch on `/quota` (text mode, 90 s timeout: "needs
/quota five-hour >=35%, weekly >=10%"). It is independent of this app, spends
nothing, and nothing here depends on it. Its runs do stamp the agent home
(and run the update check), which is why runs 1–3 here found the update
debounce already armed. It doesn't matter for this design.

### `--settings` and the status line

`agy --help`: "`--settings` — Settings for this session only, never saved: a
JSON object of settings.json keys, inline or as a file path". The public
docs don't mention the flag. The coordinator above starts its sessions
with a per-branch `--settings` file. Whether a `statusLine` in the default
`settings.json` survives beside it can't be checked with the invocations
this work may make, because it needs an interactive session. It no longer
matters: print-mode runs never start a custom status line (changelog: they
"no longer start your custom status line"), and the route above uses none.

## The spec §10 amendment (lands FIRST, before provider code)

In `docs/SPEC.md` §10, replacing the status-line sub-clauses of the
Antigravity amendment and its "scripting the CLI … ruled out" sentence, and
in `docs/PRIVACY.md` (the user-readable record, the summary table's
Antigravity row, and its Antigravity section rewritten). The text states:

- **What runs, how often.** Exactly `<agy> -p /quota --output-format json
  --log-file /dev/null`, environment `HOME USER LOGNAME TMPDIR`, `PATH=/usr/bin:/bin:/usr/sbin:/sbin`
  and `AGY_CLI_DISABLE_AUTO_UPDATE=true`, cwd `/`, stdin `/dev/null`, utility
  QoS. At most once per 10 minutes, only while a conversation has been
  written since the last reading, one at a time, killed at 30 s, backing off
  to 2 h after failures. Only in the engine host. Plus a one-off `--version`
  per binary file identity. Never an agent turn, never another subcommand.
- **What the vendor's process writes inside its home** (measured, the
  superset of every run): mtime stamps on `cache/onboarding.json`,
  `conversation_summaries.db`, `crashes/`; and — unless the CLI ignores its
  documented `--log-file` and update switch — a log in `log/`, the `cli.log`
  link, an `implicit/*.pb`, and the update check's `last_check.timestamp` /
  `updater/`. Its own sign-in token may be refreshed and written back to its
  own Keychain item or its own file fallback.
- **What goes over the network and who sends it.** The vendor's process, to
  Google's Cloud Code backend (`daily-cloudcode-pa.googleapis.com`, measured),
  under its own sign-in, the same requests any start of the CLI makes. Not an
  app destination: the app opens no connection, and the four destinations
  stay four.
- **The app itself** still never writes inside an agent home, never reads a
  credential, the Keychain or a token, and keeps only bucket ids, fractions
  and resets — the payload's text, descriptions and anything else are dropped
  before anything touches the disk. stdout and stderr are never logged.
- The status-line export clause is retired. Its carve-out from the
  single-writer rule goes with it.

CLAUDE.md: the "NEVER WRITE INSIDE AN AGENT HOME" rule gains the by-proxy
sentence (the vendor's process the provider spawns stamps its own files; the
app writes nothing), and the network-destinations rule gains one line: the
Antigravity provider's quota probe runs the vendor's CLI, whose own traffic
goes to Google under its own sign-in, and is not an app destination
(`UsageProvider.quotaCommand`, not `networkDestinations`).

## Design

### Core, vendor-neutral (new `Sources/UsageCore/AgentCommands/`)

- `AgentQuotaCommand` (declared by a provider through a new
  `UsageProvider.quotaCommand: AgentQuotaCommand?`, default nil): executable
  candidates, a version argument and its acceptance test, arguments, extra
  environment, timeout, floor, a pure `reduce(output, now) -> reduced
  reading | failure kind`, and the privacy-card phrasing (the command line as
  shown, what its process writes, where it connects). Core clamps the floor to
  ≥ 10 min (`AgentQuotaCommand.minimumFloor`), the way `TriggerGate.floor`
  holds the endpoint.
- `AgentCommandRunner` (the seam tests replace) and `SpawnedCommandRunner`
  (the real one): `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` (only
  stdin `/dev/null` and two pipes reach the child, never `engine.lock`'s fd
  or the control socket), `POSIX_SPAWN_SETPGROUP` (its own process group),
  `posix_spawnattr_set_qos_class_np(QOS_CLASS_UTILITY)`, and a cwd file
  action. Pipes are drained asynchronously with caps (stdout 256 KB, stderr
  16 KB; over the cap = failure and kill). Completion is the child's EXIT,
  never pipe EOF — a grandchild holding stdout open can't stall it (a 1 s
  drain after exit). On timeout: SIGTERM to the group, 2 s, SIGKILL to the
  group, reaped. Returns exit status, capped output, timed-out flag and
  duration. Utility, not background: background QoS can stretch a 2 s run
  past any honest timeout on a loaded Mac (the 254 s heartbeat gap, 2026-11-21).
- `AgentQuotaProbe` (an actor, one per engine): the gate (`AgentQuotaSchedule`,
  pure, unit-tested), single flight (a second caller during a run waits for
  it and gets its outcome, never a second spawn), the binary check, and
  `AgentQuotaProbeStore` — `quota-probe.json` in the engine's support folder:
  `{version, binary identity + accepted, lastAttemptAt, lastOutcome,
  consecutiveFailures, reading: {startedAt, capturedAt, data}}`, atomic,
  0600. The gate:
  - binary resolved and accepted, else nothing runs and nothing is shown;
  - not in flight;
  - `now ≥ lastAttemptAt + interval`, interval = floor (10 min, 30 s
    slack so a 5-minute poll lands on it) or the backoff after
    `consecutiveFailures` (20, 40, 80, then 120 min);
  - the newest conversation write (the provider's watch directories, via
    `LocalActivitySource.lastActivity`) is later than the reading's
    `startedAt`, and within the last 7 days.
- Outcomes → `UsageError`, vendor-neutral, additive (digest `code` is an open
  string in Swift and Rust): not signed in → `noCredentials` ("No Antigravity
  CLI sign-in found" / "Sign in to Antigravity CLI, then refresh."), timed
  out → new `agentTimedOut`, output unreadable → new `agentOutputUnreadable`,
  exited non-zero / couldn't launch → new `agentCommandFailed`. Not signed in
  is recognised only by a structural signal the reducer can see (non-zero
  exit plus a sign-in phrase in stderr) and falls back to the generic failure;
  that output was never observed (signing out would touch the account).
  Never `.network`: `fetchWithOneRetry` would re-fetch.

### Where it hooks in

- `MeteringHost.Configuration` gains `agentCommandRunner: (any
  AgentCommandRunner)?`, default nil. usaged and the app's hosting path pass
  `SpawnedCommandRunner()`; tests, the snapshot hatch and every client leave
  it nil, so nothing there can spawn.
- `UsageEngine` builds an `AgentQuotaProbe` when both the provider declares a
  command and the host supplied a runner, and hands it to `UsageService`
  (three lines; the engine file is already past 600 and gets no logic).
- `UsageService.refresh`: `await probe?.runIfDue(now:)` before the fetch,
  then the provider's ordinary `fetchRawUsage`, then, if the probe's STANDING
  outcome (persisted, so a restart restores it) is a failure newer than its
  reading, `.cached(snapshot, error)` instead of `.live`, and the body is
  still cached. Focus then always sees a snapshot; the error renders where
  every other fetch error already does (panel error block, digest error,
  TUI, `usage-cli`).
- `AntigravityProvider.fetchRawUsage` reads the probe's reading from
  `quota-probe.json` (the provider computes the same scoped path it computes
  for the export file today) and keeps today's rules: no reading and no
  transcripts → `noLocalData`; a reading or transcripts → the payload, with
  `fetchedAt` = the run's finish.

### Provider

- `AntigravityProvider.quotaCommand`: the candidates above, `--version`
  accepted when it prints one line matching `^\d+\.\d+(\.\d+)?$`, the
  arguments and the update switch above, timeout 30 s (12× the measured
  wall, room for a loaded Mac and a slow network), floor 10 min (1/30 of the
  shortest window, so a reading is never more than ~3% of it stale; six runs
  an hour at most).
- `AntigravityQuota.reduce(quotaOutput:)` beside the existing snapshot code:
  decodes only `command.data.groups[].buckets[].{id, remaining_fraction,
  reset_time}` (lenient per bucket, as today), `status` (anything but
  `SUCCESS` is a failure), and nothing else — no `response`, no names or
  descriptions. The epoch (or any reset before 2001) → no reset. Bounds kept.
  The narrowed "spent" rule above.
- `AntigravityQuotaReading` loses `planTier` and `cliVersion` (no source any
  more); the `version` stays 1. A cached body from the old build still decodes
  (unknown keys are ignored).
- `shape(of:)` meters the `gemini` pool only; `3p-*` returns nil (skipped),
  and the third-party constants (`thirdPartyName`, `thirdPartyScope`,
  `shortWindow`) and the rank-2 branch go.
- `pricingSelector` → `PricingFeedSelector.gemini`; `modelCatalog` →
  `.gemini` (checked in the build: how Gemini's grammar displays a
  non-Gemini id; if it mangles one, a generic fallback for unclaimed ids,
  never Claude's or Codex's grammar).
- Labels, ids, ranks, the Gemini scope and the rolled-window rule:
  unchanged. No history exists under the pool's labels on any install (no
  reading ever landed: the status line was never set up and #36 is
  unreleased), so dropping them strands nothing. The build checks anyway
  that no view lists a label without a current meter.

### The status line

Removed, not kept as a second source: it never ran here (`settings.json`
holds only `trustedWorkspaces`), print-mode runs never start it, sessions
started with `--settings` may never see it, and its payload shape was
never verified and can't be with the invocations allowed. The probe makes it
redundant at a 10-minute freshness. Going: `StatusLineExport.swift`, the
`statusLineExport` requirement, `StorageScope.statusLineExportFile`, the
`export-statusline` verb in usage-cli, its tests, the SPEC/DAEMON/CLI/
PRIVACY/HARNESSES/README text, the Settings caption
(`GeneralSettingsPane`), the privacy-card line (`HarnessPrivacyBlock`), the
snapshot hatch's comment, and the release note. #36 is in no release, so
no shipped install loses anything. A stale `statusline-export.json` on a dev
machine is simply never read again.

### UI and docs

- Privacy card, Antigravity block: the two read paths (unchanged), then
  "Runs `agy -p /quota` (its own print mode) at most every 10 min while you
  use it — the CLI asks Google with its own sign-in; only its limits are
  kept", and "The CLI stamps its own files under
  `~/.gemini/antigravity-cli` when it runs". Rendered generically from the
  declaration; the app names no vendor.
- Settings caption: drops the status-line sentence.
- The snapshot hatch's Antigravity cell: S·W (no C).
- `docs/HARNESSES.md` (user section: "nothing to set up", Gemini only;
  internals: the probe, LIMITS rewritten, TWO POOLS replaced by "one pool
  metered, Gemini-scoped; a non-Gemini call counts unpriced"),
  `docs/PRIVACY.md`, spec §10, CLAUDE.md, `docs/CLI.md` (verb
  removed), `docs/DAEMON.md` (carve-out removed; the probe runs in the engine
  host), `docs/ARCHITECTURE.md` (one line on the seam), README privacy
  paragraph, `.release-notes/next.md` (the Antigravity entry rewritten, not
  appended), and `docs/plans/antigravity.md`'s decision record.

## Tests (no test spawns the real CLI)

- Reducer, on synthetic fixtures with the real shape
  (`Tests/UsageCoreTests/Fixtures/antigravity-quota-*.json`, every name,
  description and text replaced by placeholders): today's reading; an
  untouched pool (epoch); a spent bucket (fraction 0); a bucket with a real
  reset and no fraction; the epoch with no fraction (NOT spent); an unknown
  bucket id; a bucket whose field types are wrong (dropped alone);
  `status: ERROR`; empty stdout; truncated JSON; non-JSON; a 300 KB stdout.
- Gate (pure): floor with slack; backoff steps and cap; no write since the
  reading → no run; first reading inside / outside 7 days; missing binary →
  no run and no error; a rejected binary (inside `.app`, `--version` with
  three lines) → no run; persisted `lastAttemptAt` honoured across a fresh
  probe (restart / handover).
- Probe with a fake runner: no concurrent runs (N callers, one spawn, all get
  its outcome); timeout → `agentTimedOut` and backoff; outcome → error →
  `.cached(snapshot, error)` with and without a prior reading; recovery
  clears the error; the reading's `fetchedAt` is the finish time.
- Real runner against system binaries only (`/bin/sh`, `/bin/sleep`):
  timeout kills and reaps; a grandchild holding stdout open doesn't stall the
  result; the group dies on timeout; the output cap; the child sees only fds
  0–2 (`/bin/sh -c 'ls /dev/fd'`); missing executable → launch failure.
- Host opt-in: a host built without a runner never constructs a probe.
- The removed status-line tests go; the meters/rolled-window tests stay.
- Gemini-only: `3p-*` buckets produce no meter; the two Gemini meters keep
  their scope and lockout; the pricing selector excludes Anthropic and
  OpenAI feed rows; a transcript call on a `claude-*` id counts its tokens
  and prices to null. Every test, fixture and snapshot model expecting
  S·W·C (the snapshot hatch's Antigravity segments, the digest goldens if
  any carry the pool) moves to S·W.

## Verification

- `mise run gate` green before every report.
- The real check (once built): an opt-in live suite in the existing style,
  `ANTIGRAVITY_LIVE_QUOTA=1 swift test --filter AntigravityLiveQuota`, runs
  the provider's command through `SpawnedCommandRunner` with a temp state
  folder (never the app's real folder) and prints the reduced meters only —
  label, percent, reset. Plus a path listing before and after it, as above.
- UI through `--snapshot` with `--demo-digest`. Today's generator
  (`scripts/demo-digest.py`) fills Claude and Codex only, so it gains an
  opt-in `--with-antigravity` that adds the harness with S·W·C meters (opt-in
  so the README's recorded media keep their bytes). The hatch renders the
  panel and the status items, not Settings, so the privacy-card lines are
  checked by a test of the vendor-neutral model they render from.
- Not verifiable here: a run under launchd itself (it needs the live install
  repointed). The environment and cwd measured are the daemon's own, and the
  timeout leaves 12× margin.

## Assumed (decisions taken without the person)

1. Remove the status-line export rather than keep it as a fresher optional
   source (reasons above).
2. Floor 10 min, timeout 30 s, backoff 20/40/80/120 min, first-reading reach
   7 days, `--version` check per file identity.
3. Failures render as `.cached(snapshot, error)`, with three new
   vendor-neutral `UsageError` cases; not-signed-in reuses `noCredentials`.
4. A manual refresh does NOT bypass the 10-minute floor.
5. The child gets a constructed minimal environment, not the host's: a
   sign-in that depends on a shell variable (`AGY_ADC_AUTH`) isn't seen by
   the daemon anyway, and `GEMINI_API_KEY` sign-ins have no quota to read.
6. `~/.antigravity/antigravity/bin/agy` is excluded from the candidates (the
   brief listed it; it is the editor).
7. No plan name for Antigravity (`/quota` has no tier).
8. The Gemini meters keep `modelScope: ["gemini"]` after the pool goes, so
   the generic scope machinery stays (still used, nothing removed from the
   digest).
9. Gemini-only catalog: Gemini's grammar alone, with a generic fallback for
   ids it doesn't claim if the build shows it needs one.

## Found (belongs elsewhere)

- The desktop app's spend: if Antigravity.app keeps its conversations
  outside `~/.gemini/antigravity-cli` (#36 open question 3), its spend never
  wakes the gate and the rolled-window rule's "0% — nothing could have been
  spent" can be wrong for it. Pre-existing; worth its own look.
- `UsageEngine.swift` is 704 lines, past the 600-line rule, before this
  branch.

## Build order

1. The §10 amendment: SPEC §10, PRIVACY.md, CLAUDE.md. Commit.
2. Core runner + tests (system binaries). Commit.
3. Gate, store, probe + tests (fake runner). Commit.
4. Provider command, reducer, fixtures, fetch, Gemini-only meters, prices
   and catalog + tests. Commit.
5. Service/engine/host hook, error cases, focus check + tests. Commit.
6. Status-line removal, UI strings, privacy card, docs, release note. Gate.
7. Live check, path listing, snapshots. BUILD DONE.
