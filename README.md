# claude-usage-menubar

Personal macOS menu bar app showing my Claude plan usage limits (session, weekly,
per-model weekly), mirroring Settings → Usage in the Claude app. Single user, not
for distribution.

## Status

Fully built: menu bar item (`✳︎ 6·17·22%`, per-segment severity colors),
panel with per-limit meters and reset times, live client with cached
fallback and readable error states, adaptive refresh (see below) plus
wake/network-restore triggers, launch-at-login toggle (off by default),
stable signing verified across rebuilds. Remaining: the §13 acceptance
checklist items that need real-world time (sleep/wake, token expiry).

## Adaptive refresh

The poll rate follows actual Claude use instead of a fixed clock (supersedes
spec §9's fixed interval). The "Refresh when active" setting (default 5 min)
is the pace while Claude is in use; sustained quiet decays it ×2 after 15
minutes, ×4 after an hour, ×8 after four hours, never slower than one poll
per hour. Two signals snap it back: FSEvents on `~/.claude/projects` (Claude
Code writing a transcript — also triggers an immediate catch-up poll after a
quiet stretch), and usage percentages rising between polls (which is how
Claude app/web use gets noticed). An HTTP 429 pauses polling — 5 minutes,
doubling per repeat up to an hour, honoring `Retry-After` up to two hours —
and heals automatically on the next success; the panel says so and shows the
retry countdown. Manual refresh still works during a pause. The panel footer
shows "idle ×N" whenever the cadence is decayed. Nothing ever polls faster
than once per 60 seconds.

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
```

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
