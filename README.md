# claude-usage-menubar

Personal macOS menu bar app showing my Claude plan usage limits (session, weekly,
per-model weekly), mirroring Settings → Usage in the Claude app. Single user, not
for distribution.

## Status

Milestone 1: credential chain + raw fetch via `usage-cli`.

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
mise run test   # unit tests
mise run cli    # build + sign + run the CLI debug tool
```

Signing uses the local `Apple Development` identity so the Keychain ACL from
"Always Allow" survives rebuilds (override with `CODESIGN_IDENTITY=...`).
