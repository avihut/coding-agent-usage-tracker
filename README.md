# claude-usage-menubar

Personal macOS menu bar app showing my Claude plan usage limits (session, weekly,
per-model weekly), mirroring Settings → Usage in the Claude app. Single user, not
for distribution.

## Status

Fully built: menu bar item (`✳︎ 6·17·22%`, per-segment severity colors),
panel with per-limit meters and reset times (subscription type under the
title), live client with cached fallback and readable error states, adaptive
refresh (see below) plus wake/network-restore triggers, launch-at-login
toggle (off by default), stable signing verified across rebuilds. Local
transcript analytics: activity heatmap (7D per-model stacked bars with
per-day totals / 30D calendar / all-time grid, each viewable by token
volume or estimated cost) with one-line day tooltips, and click-to-drill
day views — a model donut plus that day's usage table, animated push/pop with a
back button; per-meter hover popovers graphing percent history overlaid
with every model's cumulative token curve — a History/Current span picker
switches between the trailing window and the limit window start-to-reset,
where a vertical now rule separates measured usage from the prediction engine's
dashed projected trajectory, a red mark pins the moment the current pace
would spend the limit (hatching the unreachable region beyond it), and an
iStat-style strip under the plot shows active-vs-idle stretches (short
pauses bridge into one session per an adjustable grace period, default
15 min, off = raw activity; the current session stays open until its
idle time outlives the grace) — with
per-poll-interval readouts and the same
breakdown table as a legend (hovering a curve or a row focuses that model
everywhere and dims the rest); a per-period model usage table
(aligned input/cached/output/cost columns — cache re-reads of the
conversation shown apart from fresh input — cost estimates at API list
prices, pricing feed fetched daily with bundled fallback) whose rows
double as a legend — hovering one filters the chart above to that model in its own
color. A sidebar-navigated settings window (⋯ menu → Settings…) holds the
general knobs — the refresh-pace slider, the session grace period, and
Claude Code's own transcript retention (`cleanupPeriodDays`, the app's one
sanctioned write into `~/.claude/settings.json`, preserving every other
key) — plus an API-cost page:
pricing-feed status with a manual refresh, the list rates in use, a Claude
Code-specific explainer of how transcripts turn into cost estimates (four
token classes, the agentic loop, quadratic cache reads), and a
session-cost playground that re-prices a simulated session live.
Remaining: the §13 acceptance
checklist items that need real-world time (sleep/wake, token expiry).

## Adaptive refresh

The poll rate follows actual Claude use instead of a fixed clock (supersedes
spec §9's fixed interval). The "Refresh when active" setting (default 5 min)
is the pace while Claude is in use; sustained quiet decays it ×2 after 15
minutes, ×4 after an hour, ×8 after four hours, never slower than one poll
per hour (or your chosen pace, when that's slower). Two signals snap it back: FSEvents on `~/.claude/projects` (Claude
Code writing a transcript — this also polls immediately whenever the shown
data is older than the active pace, so re-engaging catches the meters up at
once), and usage percentages rising between polls (which is how Claude
app/web use gets noticed). An HTTP 429 pauses polling — 5 minutes,
doubling per repeat up to an hour, honoring `Retry-After` up to two hours —
and heals automatically on the next success; the panel says so and shows the
retry countdown. Manual refresh still works during a pause. The panel footer
shows "idle ×N" whenever the cadence is decayed.

Nothing ever polls faster than once per **180 seconds** (supersedes the spec's
60s floor, and the app's own earlier 1-minute option). Field evidence: this
endpoint rate-limits sustained sub-3-minute polling into sticky 429s — this
app hit it at 60s, and community testing found the same
([anthropics/claude-code#31637](https://github.com/anthropics/claude-code/issues/31637),
[#31021](https://github.com/anthropics/claude-code/issues/31021)). The pace
is set in the settings window with a logarithmic slider — 3 minutes to 2
hours, snapping to marked stops at 3/5/15/30 minutes and 1/2 hours — while
the panel's ⋯ menu keeps 3/5/15 quick picks. A request ledger tracks the trailing
hour of calls against an estimated budget (20/hour to start, tightened
whenever a real 429 reveals a lower ceiling and remembered across launches);
the footer shows `API n/Nh` once half the budget is spent and the refresh
button turns orange/red as manual clicks approach it.

## Why this is OK (policy note)

This app authenticates with my local Claude Code OAuth access token and calls
`https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint the
Claude app's own Usage screen uses. Reasoning for why this sits on the safe side
of Anthropic's subscription-auth policy:

- It consumes zero model capacity and makes no inference calls.
- It is strictly read-only over my own account's usage state.
- It has exactly one beneficiary: me, on my own machine.
- It sends its own honest `User-Agent` (`claude-usage-menubar/<version>`), never
  impersonating Claude Code or the Claude app.

If this app ever grows a feature that calls a model, it switches to API-key auth
at that moment.

### Second network destination: the pricing feed

Cost estimates need current API list prices and Anthropic publishes no pricing
API, so the app fetches LiteLLM's community-maintained
`model_prices_and_context_window.json` from `raw.githubusercontent.com` — a
plain unauthenticated GET carrying only the app's own User-Agent, at most once
per day (attempted at most hourly while stale), filtered down to Anthropic
models and cached in App Support. This deliberately amends spec §10's
"api.anthropic.com only" rule (user-directed, 2026-08-13); nothing about the
account, the token, or local usage is ever sent there. If the fetch fails, a
pricing table bundled at build time keeps estimates rendering, marked as such.
Estimates are list-price counterfactuals ("what would this have cost on the
API") — subscription plans don't bill per token.

### Third network destination: the status page

The app shows whether Claude itself is up, so it reads Anthropic's own public
status page — `status.claude.com` (an Atlassian Statuspage;
`status.anthropic.com` redirects there). One endpoint,
`/api/v2/summary.json`, roughly 2 KB, as a plain anonymous GET on a
cookie-less session with an `If-None-Match` header and nothing else: no
sign-in, no account data, no query parameters. It is the same page anyone can
open in a browser, and the request says no more about me than opening it
would.

Polling idles at five minutes and tightens to one minute only while an
incident is open, so the all-clear arrives promptly without ever asking more
often than the page's own ten-second CDN cache could answer. Nothing fetched
is written to disk. This amends spec §10 (2026-08-19); a status host is
declared per provider and shown on the settings privacy card, and providers
that declare none stay entirely offline.

### Fourth network destination: this app's own releases

Standalone installs (the app living in /Applications rather than inside a
git checkout) check this repository's newest GitHub release every six hours —
one anonymous conditional GET of
`api.github.com/repos/avihut/coding-agent-usage-tracker/releases/latest` on a
cookie-less session, nothing identifying beyond the public repo path. When a
newer version exists, a small accent arrow appears beside the version label
in the panel footer; one click downloads the release zip (from
`github.com`, redirecting to GitHub's asset CDN — the only automatic-nothing
download, it happens exclusively on that click), verifies its code signature
and version, swaps the app bundle in place, restarts the background engine,
and relaunches. Settings → General governs it: check now, automatic checks
off, or skip a version. A build sitting inside a git checkout polls the same
anonymous feed — knowing it's behind is half the point — but only informs:
its update path stays `git pull` and a rebuild, and the app swaps nothing
(distribution channels, 2026-08-23). This amends spec §10 (2026-08-23).

### One local identity read: which account is signed in

Claude Code's transcripts carry no account identity, so switching accounts
would silently blend two budgets into one history. The app therefore reads
one key (`oauthAccount`) of `~/.claude.json` — the file `/login` itself
maintains — strictly read-only, and keeps a small local ledger of which
account was signed in when. Usage is attributed against that timeline
honestly: exactly inside observed stretches, only by agreement across
unobserved gaps, and never at all for history from before the ledger
existed — ambiguity is shown as ambiguity, not guessed away. The identity
never leaves the machine: it is not attached to any request, and this read
adds no network destination. It is also deliberately NOT the Keychain — no
new credential reads, so no consent prompts, ever. This amends spec §10
(2026-08-25).

## Known risk: undocumented endpoint

`/api/oauth/usage` is not in the public API docs and may change shape or go away
without notice. Consequences for the code: every response field is optional,
unknown limit kinds render generically, and schema changes degrade to a readable
error state — never a crash or a blank menu bar item. The network layer is
isolated so a migration to a supported endpoint, if one ships, is a one-file
change.

## Credential rules (non-negotiable)

- Read `~/.claude/.credentials.json` first, fall back to the login Keychain item
  `Claude Code-credentials` — read via `/usr/bin/security find-generic-password`,
  the same Apple tool Claude Code writes it with, so the read never trips the
  Keychain consent dialog (Claude Code rewrites the item on every token refresh,
  which resets any per-app "Always Allow" a native read had earned).
- Access token only. The refresh token is never read or used.
- Never write to the Keychain. Never cache the token in memory or on disk —
  re-read every refresh cycle so Claude Code's own token refresh is picked up.
- The token is never logged, persisted, put in a URL, or included in any error.
- No feature may require entering system credentials (Keychain consent, admin
  authorization) for the app's regular operation — the promptless read above
  is the standing mechanism. Any narrowly-scoped exception needs its own
  documented spec §10 amendment reasoning out why no promptless path exists.

## Build / run

```sh
mise run app    # build + bundle + sign + launch the menu bar app
mise run test   # unit tests
mise run cli    # build + sign + run the CLI debug tool (prints raw JSON)
mise run bundle # assemble + sign the .app without launching it
```

Every lifecycle script in `scripts/` has a matching mise task — `mise tasks`
lists the full catalog, including the AX verification pair
(`axdump` / `axpress`).

### Code signing

Nothing in the repo names a developer account. Every build signs with an
identity resolved on the machine doing the building (`scripts/sign.sh`), in
this order:

1. `CODESIGN_IDENTITY`, if set — pin one per checkout by copying
   `mise.local.toml.example` to `mise.local.toml` (git-ignored) and running
   `mise trust`.
2. The login keychain's first code-signing identity, preferring
   `Developer ID Application` > `Apple Development` > `Mac Developer`.
3. Ad-hoc (`-`), with a warning.

```sh
mise run identity   # which identity builds will use, and where it came from
```

A fresh clone with no certificate at all builds and runs ad-hoc: the app,
daemon, and CLI all work, since the Keychain read goes through Apple's
`security` tool rather than our own signature. What ad-hoc costs is
*stability* — every rebuild is a new identity to macOS, so Gatekeeper and
launchd re-evaluate the bundle each time. A real certificate fixes that and
needs no paid membership: sign into Xcode with any Apple ID (Settings →
Accounts), then Manage Certificates → **+** → Apple Development. Those
certificates last a year; when one expires, `mise run identity` falls back to
ad-hoc and signing warns — renew it in the same place, and the identity
survives because its name does.

`mise run dist` refuses ad-hoc outright (`CODESIGN_REQUIRE_IDENTITY`): a
release zip must carry a timestamped signature from a real identity, or the
in-app updater's `codesign --verify` and Gatekeeper reject it on the
receiving Mac.

## The terminal dashboard (usage-tui)

A full-screen TUI face for tmux panes (`tui/`, Rust + ratatui): reads the
engine's `live-state.json`, computes nothing, and re-plans its layout from
the pane's shape — portrait stacks the sections, landscape splits into
columns, and anything under ~10×40 collapses to a one-line strip
(`✳︎ S 34 · W 59 · F 92`). Keys: `q` quit, `r` ask the engine to refresh
(over the control socket), `?` help. Works against the app-hosted engine
or the daemon interchangeably.

```sh
mise run tui        # build + run in this terminal
mise run tui-test   # digest contract + layout tests
```

Detail surfaces open from the dashboard: click a meter (or `1-3`) for its
window chart — measured percent in braille, forecast trajectory, session
stretches, `←→` scrub, time and percent axis labels once the pane affords
them — and click a heatmap day to drill into hourly bars and per-model
rows (`[ ]` pages the calendar; everything hovers — a model row re-colors
the heatmap to that model alone, as in the app). No mouse needed: the
arrow keys drive a focus cursor across whatever is interactive — it wears
the same lift (bold + brightened color) and readouts as hover — and
`enter` opens it. For the tmux
status bar, `usage-tui --status` prints one colored segment line:

```tmux
set -g status-right '#(usage-tui --status)'
```

`NO_COLOR` switches risk to `!` markers and the heat ramp to ░▒▓█ density;
non-UTF-8 locales (or `USAGE_TUI_ASCII=1`) drop to a plain-ASCII alphabet.

The digest schema is pinned on both sides of the language boundary: the
Swift tests and the TUI's serde tests decode the same golden fixtures in
`Tests/UsageCoreTests/Fixtures/digest/`.

## The headless engine (usaged)

The metering engine runs as a launchd user agent, `usaged` (embedded in
the app bundle), so consumer interfaces — the TUI, or the menu bar app
itself — render with nothing else open. The daemon wins: while it runs,
the app renders its published `live-state.json` digest and sends commands
over a local socket; quit the daemon and the app hosts the engine embedded
again within moments (`docs/DAEMON.md` has the full design).

Installation is automatic: the app sets the agent up at launch (and heals
it — a moved bundle is repointed, an outdated daemon restarted), and the
TUI does the same when it finds no engine running. There is nothing to
approve: the daemon reads the Claude Code token through Apple's own
`security` tool — the same client Claude Code stores it with — so no
Keychain consent dialog ever appears.

```sh
mise run daemon -- status     # launchd state, digest age, socket ping
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

## Install on another Mac

The easy path: grab `ClaudeUsage-<version>.zip` from the [releases
page](https://github.com/avihut/coding-agent-usage-tracker/releases) —
`mise run publish` puts one there per tagged version. From then on the app
updates itself: it notices the next release and installs it in one click.

To build the artifact locally instead:

```sh
mise run dist   # universal (arm64 + x86_64), signed with a timestamp, zipped
```

That writes `dist/ClaudeUsage-<version>.zip` and verifies the signature survives
the round trip. On the target Mac:

```sh
ditto -x -k ClaudeUsage-<version>.zip /Applications
xattr -dr com.apple.quarantine /Applications/ClaudeUsage.app
open /Applications/ClaudeUsage.app
```

The `xattr` step only matters when the transfer set the quarantine bit — AirDrop,
browser downloads, and Messages do; `scp`, `rsync`, and USB sticks don't. Strip
it *before* the first launch: this app is signed with an Apple Development
certificate rather than a notarized Developer ID one, so Gatekeeper rejects it
(`spctl -a` says so here too), and the "Open Anyway" button only appears under
System Settings → Privacy & Security *after* a launch has already been blocked.

The target Mac needs macOS 15+ and Claude Code installed **and signed in**: the
app carries no token, it reads that machine's own login Keychain item, so nothing
of mine travels inside the zip. There is no Keychain dialog to approve — the
item is read through Apple's `security` tool, the same client Claude Code
stores it with. The first launch sets up the background engine (`usaged`) by
itself — that's the whole install.

Keep the bundle in `/Applications`: `SMAppService` registers the launch-at-login
item by path, so moving the app afterwards breaks that toggle.

The signature is timestamped, so it stays valid after the signing certificate
expires. Rebuilding on the target Mac (`daft clone` + `mise run app`, signing
with that machine's own identity — see [Code signing](#code-signing)) is the
other route, and sidesteps Gatekeeper entirely.
