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
with every model's cumulative token curve — a Sliding/Window span picker
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

## Known risk: undocumented endpoint

`/api/oauth/usage` is not in the public API docs and may change shape or go away
without notice. Consequences for the code: every response field is optional,
unknown limit kinds render generically, and schema changes degrade to a readable
error state — never a crash or a blank menu bar item. The network layer is
isolated so a migration to a supported endpoint, if one ships, is a one-file
change.

## Credential rules (non-negotiable)

- Read `~/.claude/.credentials.json` first, fall back to the login Keychain item
  `Claude Code-credentials`.
- Access token only. The refresh token is never read or used.
- Never write to the Keychain. Never cache the token in memory or on disk —
  re-read every refresh cycle so Claude Code's own token refresh is picked up.
- The token is never logged, persisted, put in a URL, or included in any error.

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

Signing uses the local `Apple Development` identity so the Keychain ACL from
"Always Allow" survives rebuilds (override with `CODESIGN_IDENTITY=...`). Those
certificates last a year; when one expires, signing fails with "no identity
found" — renew it in Xcode → Settings → Accounts → Manage Certificates. The
name stays the same, so the ACL survives.

## Install on another Mac

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
of mine travels inside the zip. On the first refresh macOS asks whether
ClaudeUsage may read `Claude Code-credentials` — click **Always Allow** once.

Keep the bundle in `/Applications`: `SMAppService` registers the launch-at-login
item by path, so moving the app afterwards breaks that toggle.

The signature is timestamped, so it stays valid after the signing certificate
expires. Rebuilding on a Mac that has Xcode and the signing identity
(`daft clone` + `mise run app`) is the other route, and sidesteps Gatekeeper
entirely.
