# Privacy, credentials and policy

What this app reads, where it connects, and why each of those is allowed.
This is the standing record of the spec §10 amendments
([SPEC.md](SPEC.md) §10 is the rule set itself); the app's privacy
inventory (Settings → General → About) renders the same facts live, from
the providers' own declarations.

In short:

| The app… | With |
| --- | --- |
| calls `api.anthropic.com/api/oauth/usage` | your local Claude Code OAuth **access** token — read-only, re-read every cycle, never stored or logged |
| fetches API list prices from `raw.githubusercontent.com` | nothing — a plain anonymous GET |
| reads `status.claude.com` | nothing — an anonymous conditional GET |
| checks `api.github.com` for this repo's newest release | nothing — an anonymous conditional GET |
| reads local files | each agent's own transcripts and session files, plus one key of `.claude.json`; read-only |
| writes inside an agent home | exactly one key, `cleanupPeriodDays` in that home's `settings.json`, and only when you move the transcript-retention control in Settings |
| keeps Antigravity's plan limits | in one file in its OWN folder, written only by `usage-cli export-statusline` when you make that your Antigravity status line; limits and plan tier only |

No other network destination, no analytics, no telemetry. Codex, Gemini
CLI and Antigravity CLI are metered from local files alone. The sections below are each
decision in full, in the maintainer's voice, in the order they were made.

## Why this is OK (policy note)

This app authenticates with my local Claude Code OAuth access token and calls
`https://api.anthropic.com/api/oauth/usage` — the same undocumented endpoint the
Claude app's own Usage screen uses. Reasoning for why this sits on the safe side
of Anthropic's subscription-auth policy:

- It consumes zero model capacity and makes no inference calls.
- It is strictly read-only over my own account's usage state.
- It has exactly one beneficiary: me, on my own machine.
- It sends its own honest `User-Agent` (`coding-agent-usage-tracker/<version>`), never
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

Since v0.93.0 the same host answers one more question, at start-up and on
wake only: `/api/v2/incidents.json`, the page's public incident history, read
the same anonymous way (no ETag needed — at most once per ten minutes). It
exists so an outage that opened AND closed while the Mac slept still shows up
as a dismissable "Outage overnight" notification the next morning; the
summary feed only remembers the last hour. Same host, same terms, no new
destination.

### Fourth network destination: this app's own releases

Every install checks this repository's newest GitHub release every six hours —
one anonymous conditional GET of
`api.github.com/repos/avihut/coding-agent-usage-tracker/releases/latest` on a
cookie-less session, nothing identifying beyond the public repo path. When a
newer version exists, a small accent arrow appears beside the version label
in the panel footer, and Settings → General says how to get it: `git pull`
and a rebuild. Settings → General governs the check: check now, automatic
checks off, or skip a version.

Releases carry no binary (2026-09-20 — see the [README](../README.md#install)),
so that is the whole story today. The one-click path is still in the code and
dormant: for an app living outside a git checkout, a release that DID carry a
zip would be downloaded on a click (from `github.com`, redirecting to GitHub's
asset CDN — never automatically), verified for code signature and version,
and swapped in place. With no asset, the same click opens the release page. A
build sitting inside a git checkout only ever informs, and swaps nothing
(distribution channels, 2026-08-23). This amends spec §10 (2026-08-23).

### One local identity read: which account is signed in

Claude Code's transcripts carry no account identity, so switching accounts
would silently blend two budgets into one history. The app therefore reads
one key (`oauthAccount`) of `.claude.json` — the file `/login` itself
maintains, `~/.claude.json` for the default home and its own copy inside
every other metered home — strictly read-only, and keeps a small local
ledger of which account was signed in when. The same key also gives the
plan's current name (`planDisplayName`, which Claude Code fetches with your
profile), so the panel calls the plan what Anthropic calls it. Usage is attributed against that timeline
honestly: exactly inside observed stretches, only by agreement across
unobserved gaps, and never at all for history from before the ledger
existed — ambiguity is shown as ambiguity, not guessed away. The identity
never leaves the machine: it is not attached to any request, and this read
adds no network destination. It is also deliberately NOT the Keychain — no
new credential reads, so no consent prompts, ever. This amends spec §10
(2026-08-25).

`usage-cli transcript <path>` (2026-09-06, v0.95.0) reads exactly the
transcript named on its command line plus the `<id>/subagents/**` files
beside it — the same read-only parse the scanner runs over
`~/.claude/projects` — so a session Claude Code wrote under another
`CLAUDE_CONFIG_DIR` (which the daemon never indexes) can be priced too, by
the same parser and the same rates. Nothing is cached and nothing leaves
the machine; this extends the transcript-read amendment to a user-named
path, not to any new tree the app walks on its own.

## Several agent homes: no new destination

This adds **no network destination**. Each enabled home polls the same
usage endpoint with its own token, through the same 180-second floor and
the same backoff; the pricing feed, the status page and the release feed
stay one poll per provider, not one per home — and since v0.101.0 the rate
feed is one poll for ALL providers, shared. Discovery is passive: the
app lists `~/.claude*` directories that look like homes, reads the one
identity key it already reads to name the offer, and reads nothing
credentialed — no `.credentials.json`, no Keychain — until you enable that
home in Settings → General → Accounts. Dismiss an offer and it stays quiet
until that home is signed in as somebody else. Each enabled home's
Keychain item is `Claude Code-credentials-<first 8 hex of SHA-256 over the
home's path>` — Claude Code's own naming rule — read through the same
promptless `security` path, so a second account is still no consent
dialog. Spec §10 amended 2026-09-06.

## Every harness at once: no new destination

This adds **no network destination**. Each harness reads exactly what it
always read: Claude its usage endpoint and its own homes, Codex and Gemini
their local session files and no credentials at all. Metering them together
grants none of them anything new, and whether a harness exists is decided by
`stat` on the directories it already declares. It is in fact one request
FEWER per day: the LiteLLM rate feed is a single mixed-vendor document that
every harness slices differently, so its bytes are now fetched once and
shared rather than once per harness. The privacy card lists every metered
harness's hosts and files, one block each — what the app reads is the union,
so the card that names it is too.

## Antigravity CLI: local transcripts and a status-line export, no new destination

(2026-11-21, user-directed.) Antigravity CLI succeeds Gemini CLI for
Google's plans, and it is metered the way Codex is: from its own files,
with no network destination and no credential.

**What it reads, read-only.** The file NAMES in
`~/.gemini/antigravity-cli/conversations/` — never a conversation
database's contents: opening a SQLite database that is in WAL mode creates
files beside it, and that would be a write inside the agent home. For each
listed conversation it reads the step log the CLI writes beside it,
`brain/<id>/.system_generated/logs/transcript.jsonl`, and decodes only
timestamps, step types, model ids and token counts — never message text,
thinking, tool calls or their output. It never walks `brain/` (which holds
worktrees), and never opens the CLI's credential or state files, or
anything belonging to the Antigravity app.

**Where the plan limits come from.** Antigravity keeps its quota on Google's
servers; nothing on disk holds it, and the only routes to it that other
trackers use — the language server's local port, the CLI's own OAuth
credential, scripting the CLI's `/usage` screen — each mean a credential,
a process or a sign-in this app does not touch. What Antigravity DOES offer
is its documented custom status line: on every redraw it runs a command you
choose and hands it a JSON payload that includes the quota. So the limits
are opt-in, and you install them yourself:

- `usage-cli export-statusline antigravity --print-config` prints the
  `statusLine` entry to add to `~/.gemini/antigravity-cli/settings.json`.
  The app NEVER writes that file — it is inside the agent home — so you
  paste it.
- On each redraw `usage-cli export-statusline antigravity` reads the
  payload, keeps ONLY the quota buckets (remaining fraction, reset time,
  disabled), the plan tier and the CLI's version, and writes them to
  `statusline-export.json` in this app's own Application Support folder
  (mode 0600; rewritten when a limit moves, otherwise at most once a
  minute). The email, the working directory, paths, the conversation title
  and everything else in the payload are dropped before anything touches
  the disk. It prints nothing and always exits 0, so the CLI's own status
  line is unchanged.
- The engine reads that file like any other local trace. It is the one file
  in the app's folders written by something other than the engine, and
  nothing else ever writes it.

Without the status line Antigravity still meters tokens, models and
activity; its limits simply aren't shown, and a harness with no limits to
show never takes the menu bar's lead unless you pin it.

**Gemini CLI is deprecated.** Its plan sign-in stopped working in mid-2026,
so for most people it writes nothing any more. It is still metered for
anyone running it on an API key, and labelled as deprecated in Settings and
`usage-cli harnesses`. Spec §10 amended 2026-11-21.

## Known risk: undocumented endpoint

`/api/oauth/usage` is not in the public API docs and may change shape or go away
without notice. Consequences for the code: every response field is optional,
unknown limit kinds render generically, and schema changes degrade to a readable
error state — never a crash or a blank menu bar item. The network layer is
isolated so a migration to a supported endpoint, if one ships, is a one-file
change.

## Credential rules (non-negotiable)

- Read the home's own `.credentials.json` first, fall back to its login
  Keychain item — `Claude Code-credentials` for `~/.claude`, suffixed with
  the first 8 hex of SHA-256 over the home's path for any other (Claude
  Code's own rule) — read via `/usr/bin/security find-generic-password`,
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
