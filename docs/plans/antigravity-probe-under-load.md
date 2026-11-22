# Antigravity's limits on a loaded Mac — plan

Branch `fix/antigravity-probe-under-load`, cut from main at 203bd8f. Follows
`docs/plans/antigravity-zero-setup.md` (#44, a43cf0d), whose quota probe
"has never produced a reading" on the person's Mac (user-reported
2026-11-22: "the tracker's still not reading antigravity limits at the
moment"). Standing direction for this harness: "There shouldn't even be a
path that requires extra work from the user to start metering antigravity".

## Up front: §10 amendment WORDING this branch changes

The amendment (spec §10, 2026-11-21 second; its user-readable record is
`docs/PRIVACY.md`) states three terms this branch corrects, all directed
by the brief and none touching the promise itself (at most one attempt
per 10 minutes, measured from the attempt's start, only while
Antigravity is in use):

| Term | Was | Becomes | Why (measured below) |
| --- | --- | --- | --- |
| the child's priority | "utility QoS" | no QoS clamp: the child runs at the default priority (31), like anything the person starts | utility (priority 20) took `--version` to 10.4 s and `/quota` to 14.3 s on saturated cores; unclamped, under 0.8 s and 3.1 s |
| the kill | "at 30 s" (`--version`: 10 s) | 120 s for both runs | a safety net against a hung child, not a latency budget: ~40× the worst unclamped run |
| a timeout | backs off like every failure (20 → 120 min) | retries at the 10-minute floor; only real failures back off | a busy Mac is transient; the backoff was meant for "signed out", "unreadable" |

## What was measured (2026-11-22, 07:03–07:35 UTC, this Mac: 10 cores)

Method: a scratch harness over a COPY of `SpawnedCommandRunner` (the QoS
call made a knob), the probe's exact environment, argv and cwd; wall time
from the runner, child CPU from `getrusage(RUSAGE_CHILDREN)`, load from
`getloadavg`, the child's priority from `ps`. Output never printed (byte
count, and the `/quota` JSON's top-level key names). COLD = a fresh
`F_NOCACHE` copy of the 229 MB binary (0.0% of its pages resident before
the run, 100% after one run: the first launch of a new file reads it
whole — the probe's version check after every CLI update). `/quota` ran
only on the real binary at its real path: 4 runs so far. CPU saturation:
N busy loops at default priority (`perl` spinning, each self-terminating),
`top` reading 0.0% idle throughout.

**The QoS API.** `posix_spawnattr_set_qos_class_np` accepts only UTILITY
and BACKGROUND (`pthread/spawn.h`; DEFAULT and USER_INITIATED return
EINVAL, checked). So "unclamped" below = no attribute set; `ps` shows the
child at priority 31 (utility: 20; under a background-policy parent: 4).

### Load average alone doesn't discriminate

Natural load 259–763 (two iOS simulators and ~20 agents; much of that
load is priority-4 and I/O-waiting threads):

| run | utility (pri 20) | unclamped (pri 31) |
| --- | --- | --- |
| `--version` warm, load 290 | 0.12–0.38 s (n=4) | 0.09–0.12 s (n=4) |
| `--version` warm, load 763 | 0.16–0.55 s (n=2) | 0.10–0.11 s (n=2) |
| `--version` cold, load 260–272 | 3.06, 3.71 s | 2.88, 3.08 s |
| `--version` cold, load 749–763 | 2.92, 3.17 s | 2.72, 2.76 s |
| `/quota`, load 691 | 2.35 s, 0.50 s CPU | 2.42 s, 0.43 s CPU |

### CPU saturation does

| busy loops (load) | run | utility (pri 20) | unclamped (pri 31) |
| --- | --- | --- | --- |
| 20 (300–323) | `--version` warm | 2.18–5.89 s, median 3.81 (n=7) | 0.12–0.18 s (n=7) |
| 20 | `--version` cold | 5.05 s | 2.74 s |
| 40 (245–325) | `--version` warm | 1.42–10.40 s, median 2.18 (n=9) | 0.27–0.68 s (n=9) |
| 40 | `--version` cold | 5.68–11.81 s (n=4) | 2.87–2.93 s (n=4) |
| 40 (325–344) | `/quota` | **14.31 s**, 0.31 s CPU | **3.06 s**, 0.40 s CPU |
| 80 (333–365) | `--version` warm | 2.91–10.35 s, median 7.45 (n=5) | 0.48–0.77 s (n=5) |

CPU per run is the same at either priority (`--version` 0.09–0.22 s,
`/quota` 0.31–0.50 s): the difference is waiting, not work. The monitor
thread's own QoS matters little (child unclamped + monitor at utility:
0.42–0.52 s against 0.30–0.32 s both unclamped, 40 loops).

### The background clamp (pre-#42 hosts)

Under `taskpolicy -b` (darwin background; the child inherits it — `ps`
shows priority 4 although the runner asked for utility): `--version` warm
0.93 and 2.72 s, COLD **214.81 s** (n=1; load moved 164 → 745 during the
run).

### Attribution

The brief's evidence — `quota-probe.json` with `binaries: []`,
`lastFailure: timedOut`, 2 failures, last attempt 2026-11-21T23:29:44Z —
predates #42 (merged 23:50:57Z), which moved the launch agent off
`ProcessType = Background`. The host then was most likely the Background
daemon, whose children run at priority 4 (the 215 s row). Since the
Interactive daemon runs, the live state has read fine: a reading at
06:35:16Z (3 s run), no failures; no attempt since only because no
conversation was written after it (newest 06:29Z) — the schedule working.
The task still stands on the saturation rows: under TODAY's host, a
utility child crosses the 10 s version kill at 40–80 busy loops (10.40,
10.35, 11.81 s), and `/quota` reached 14.3 s of its 30.

## Decisions

1. **Priority: no QoS clamp on the child.** `SpawnedCommandRunner` drops
   `posix_spawnattr_set_qos_class_np` (its only legal values are the two
   that starve it); the child runs at default priority, like the agents and
   anything the person starts. 0.1–0.5 s of CPU per run, at most every 10
   minutes. The monitor thread (asleep in `poll()` almost always) moves
   from utility to default. Named in `EngineWork` (`agentCommandQoS`, with
   the measurement), and a new SwiftLint custom rule forbids
   `posix_spawnattr_set_qos_class_np` in Sources, so a "polite" retune
   can't quietly bring the starvation back.
2. **Timeouts: 120 s, one safety net for both runs.** `AgentQuotaProbe
   .versionTimeout` (10 s) goes; the version check uses the command's own
   `timeout`, which the provider sets to 120 (was 30). Worst unclamped run
   measured: 3.06 s (`/quota`, 40 loops), 2.93 s (cold `--version`) — ~40×
   headroom; ~8× even over the worst utility run. Not sized for a
   background-clamped host (215 s cold): no host may be one (#42; CLAUDE.md
   never-again).
3. **A timeout is transient.** Either stage timing out records
   `lastFailure = .timedOut` (shown) and stamps the attempt (the floor
   holds), but leaves `consecutiveFailures` exactly as it was — neither
   escalates nor resets. So a run of timeouts retries at the floor (10
   min); a real failure (not signed in, unreadable, failed, not a limits
   command) keeps doubling; a success clears both. No state-file schema
   change: no version bump, no new failure case, no new field (app and
   daemon of different builds share `quota-probe.json`, and a `load` that
   returns nil would lose `lastAttemptAt` and break the floor).
4. **The version check stays**, at the shared 120 s. It is remembered per
   file identity once it finishes, so it costs one run per CLI update; it
   simply never finished. Considered and rejected: a code-signature
   (team ID) check — Homebrew's `bin/agy` may be a wrapper script, and it
   adds a Security-framework path for no gain; skipping it — a same-named
   launcher would receive `-p /quota`.
5. **What the faces show.** The digest already carries each error's text
   and hint, and every face prints them (panel error block, TUI, CLI). Only
   `agentTimedOut`'s words change: from "didn't answer — limits not
   refreshed" to a waiting/retrying reading (the CLI was slow because the
   Mac is busy; it's asked again on its next check while Antigravity is in
   use; limits already read stay shown). No new error code (an older face
   reads an unknown code as "Network unavailable"). Checked from demo
   digests in two states — no reading yet, and an old reading — through
   `--snapshot --demo-digest`, `usage-tui --status`, `usage-cli … --digest`;
   absent stays absent (no meter, never 0%). AS BUILT: one core predicate,
   `UsageError.isRetrying` (only `agentTimedOut`), also softens the tone —
   `usage-cli status` says `RETRYING:` instead of `ERROR:`, the TUI's
   freshness line prints it dim instead of the warning colour, and the
   panel's error text stays grey with no snapshot and its status row keeps
   the reading's stamp instead of an orange "cached".
6. **The refresh hold, accepted.** `UsageEngine.refresh` awaits the probe
   with `isRefreshing` set, so a hung child now holds that one engine for up
   to 2 × 120 s (was 10 + 30): a manual refresh meanwhile is dropped, the
   cached snapshot stays on screen (cached-first, #42), and a first-ever
   start with no cache reads "loading" until it ends. Typical unclamped
   runs are 0.3–3 s, so only a hung CLI pays it. Decoupling the probe from
   the fetch (run in the background, land a refresh when it ends) is the
   bigger change; recorded, not built. A test proves what's known stays
   shown while a slow probe runs.
7. **The flaky `forkDedup`: a clock-dependent test, not an ordering bug.**
   The one recorded failure (another worker's gate log, closed 00:59:11
   local) reads `messages → 1`, `tokens → 550`, `prompts` passing. The test
   puts the shared rows at `t0 = now − 3600` and the fork's extra call at
   `t0 + 60`: run in the minute before 01:00 local, that call lands on the
   NEXT local day, and `daily.first` holds only the shared call. The random
   ids aren't the cause: `aggregate` visits paths in sorted order and both
   orders give the same totals (and a missed dedup would double the prompt
   too). Five tests in the suite share the pattern (5–60 s windows a day);
   no other suite does. Fix: the suite's `now` becomes yesterday at 12:00
   local, so every relative row (± 11 h) lands on one local day whatever
   the clock says. Proof: the unfixed body with `now` pinned to 00:59:30
   local fails exactly as recorded (red), then green; plus one test that
   straddles midnight ON PURPOSE and checks the rows split across the two
   days and sum to the whole.

## Build steps (test first)

1. Probe tests (fake runner): a slow version run and a slow `/quota` run
   both get the 120 s safety net (the invocations carry it); a version
   timeout then a success; a quota timeout then a success; timeouts retry
   at the floor and never escalate; a real failure after a timeout still
   doubles from where real failures left it; two hours of polls every 60 s
   with every run timing out — every gap between attempt starts ≥ 600 s
   (the floor never broken), manual refreshes included. The existing
   `failures` and `unsettledVersion` tests assert the old escalation and are
   rewritten deliberately.
2. `AgentQuotaProbe`: timeouts don't touch `consecutiveFailures`;
   `versionTimeout` removed. `AntigravityProvider.quotaCommand.timeout` 120.
3. `SpawnedCommandRunner`: no QoS attribute; monitor at
   `EngineWork.agentCommandQoS`. SwiftLint rule. A real-runner test that a
   child running longer than the old limits (a few seconds of `sleep`)
   isn't killed under a long timeout already exists in spirit — extended
   if not.
4. `UsageError.agentTimedOut` text and hint; the `failureText` test.
5. Engine test: a probe that takes a while leaves the cached snapshot shown.
6. The flaky suite: pinned `now`, the deliberate straddle test.
7. Docs: `docs/HARNESSES.md` (the user paragraph's "timed out" wording
   and the probe bullet), `docs/DAEMON.md` "Under load" (the child's
   priority, the table above), spec §10's amendment terms, `docs/PRIVACY.md`
   ("stopped after 30 seconds", the backoff), and the CLAUDE.md never-again
   on background priority gains "and never clamp a child the host spawns".
   Release note in the PR body: `Fixes:` — Antigravity's limits now arrive
   on a busy Mac.

## Verify

- Unit tests above; full `mise run gate` (baseline 2026-11-22 07:36Z:
  green, 1414 Swift tests, 111 TUI).
- LOAD REPRODUCTION, before (a `git archive` of main, built in the
  scratchpad) vs after (a copy of this branch, built in the scratchpad):
  the REAL `AgentQuotaProbe` over the REAL runner and the real `agy`, with
  isolated state — but its "quota" step swapped for `--version` and a stub
  reducer, so it spends no `/quota` run. Warm and cold (a fresh copy as the
  candidate), 40 and 80 busy loops, ≥ 5 runs a cell: before should time out
  at 10 s some of the time; after never.
- ONE real `/quota` end-to-end after the fix (the 5th of the ~5 the brief
  allows), through the opt-in `ANTIGRAVITY_LIVE_QUOTA=1` test, under 40
  busy loops.
- `forkDedup` alone 50× green, and the deterministic red/green above (50×
  green alone proves nothing on its own: 50 + 160 + 6 runs were already
  green without the fix).
- The live install untouched: `quota-probe.json` read, never written; no
  `mise run app`, no launch agent, no `main/AgentUsage.app`.

## Assumed (decisions taken without asking)

- The §10 wording changes above are within the brief's direction (it asks
  for these exact three changes); recorded in spec §10 and PRIVACY.md as
  dated corrections, not flagged as `blocked`.
- 120 s for both runs (the lead guessed ~2 min; the numbers support it).
- Unclamped (default priority) rather than utility; nothing above default.
- A timeout leaves `consecutiveFailures` as it was (doesn't reset a real
  failure's backoff either). A state file left by an older build with
  timeouts counted keeps that backoff until its next success — no
  migration.
- The refresh hold (decision 6) is accepted, not decoupled.
- `--version` stays the proof of identity.

## Found (belongs elsewhere)

- The hosting APP has no App Nap opt-out (`beginActivity`), and whether a
  napped app clamps the children it spawns is unverified (launching a dev
  app is off limits here). If it does, a cold first run there could exceed
  120 s (215 s measured under `taskpolicy -b`).
- A child still running when its host exits outlives it: it sits in its
  own process group, and nothing is left to kill it at the timeout.
  Pre-existing; harmless for a CLI that exits in seconds.

Raw rows: [`antigravity-probe-under-load/measurements.log`](antigravity-probe-under-load/measurements.log).

## Results (build, 2026-11-22)

- LOAD REPRODUCTION (the real `AgentQuotaProbe` + `SpawnedCommandRunner` +
  `agy`, isolated state, "quota" step = `--version`; 5 runs a cell):

  | busy loops | before (main 203bd8f) | after (this branch) |
  | --- | --- | --- |
  | 40, warm | 4.65–10.15 s, 0/5 timed out | 0.67–0.83 s, 0/5 |
  | 40, cold | 10.94–17.19 s, **1/5 timed out** (backoff → 1) | 3.24–4.07 s, 0/5 |
  | 80, warm | 3.64–16.14 s, **2/5 timed out** | 0.46–4.82 s, 0/5 |
  | 80, cold | 9.05–15.03 s, **4/5 timed out** | 4.05–10.94 s, 0/5 |

  Before: 7 of 20 attempts died at the 10 s version kill, each one pushing
  the next try to 20 minutes and beyond. After: 0 of 20. (The 10.94 s
  after-row ran while load spiked to ~970.)
- END TO END: the one real `/quota` after the fix (5 in all), through the
  opt-in `ANTIGRAVITY_LIVE_QUOTA=1` test under 40 busy loops at load 769:
  3.49 s, all five buckets.
- FACES, from two demo digests (a timeout with no reading yet; with a
  reading 9 h old): the panel (unbundled debug binary, `--demo-digest
  --snapshot`; no bundle was assembled, so Spotlight had nothing new to hand
  a live `ensure`), the TUI's own renderer, and `usage-cli status|limits
  --digest` (exit 0; `RETRYING: …`; no meter rows when nothing was read).
- FLAKE: the unfixed suite with `now` at 00:59:30 local failed exactly as
  recorded (`messages → 1`, `tokens → 550`); fixed, 50/50 alone.
- RED-THEN-GREEN: the new probe tests against the old escalation: 19 issues;
  the priority test against the old utility clamp: priority 20, red.
