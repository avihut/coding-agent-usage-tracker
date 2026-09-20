# coding-agent-usage-tracker — agent guidelines

"Agent Usage": a macOS menu bar app (LSUIElement), a launchd daemon, a CLI
and a Rust TUI that meter coding agents' plan limits — Claude Code from the
undocumented `/api/oauth/usage` endpoint, authenticated with the local Claude
Code OAuth access token; Codex and Gemini CLI from their local files. Open
source (MIT) and SOURCE-ONLY: no binary is published, every install is built
and signed by the Mac that runs it, so whoever runs your change is trusting
it with their own sign-in. The build contract is `docs/SPEC.md` (§10 is the
hard rules). Push back on the spec when reality disagrees with it; record
corrections in the README rather than silently deviating.

This file is for anyone's agent working in this repo — contributor or
maintainer. The docs carry the project's history in the maintainer's voice
("user-directed", "user-reported" name who asked for a decision, not you).

Detail lives in `docs/`. This file holds only what must be true before you
read anything: the hard rules, where to look, and the mistakes that are
expensive to repeat. **Read the doc for the area you are about to touch
before you touch it** — every one of them was written because something
was learned the hard way.

## Hard rules (spec §10 — non-negotiable, flag rather than work around)

- Never write to the Keychain. Never read or use the refresh token — access
  token only, re-read on every refresh cycle, never cached in memory or disk.
- UNDER NO CIRCUMSTANCES may a feature require the user to enter system
  credentials — Keychain consent, admin authorization, TCC prompts — for the
  app's REGULAR operation (user-directed §10 amendment 2026-08-25). The
  v0.82.1 promptless credential path (`/usr/bin/security`, see below) is
  the standing mechanism; never replace it with a native read. A very
  specific dedicated feature MAY be an
  exception, but only with its own well-reasoned, documented §10 amendment
  spelling out why no promptless path exists.
- The token is never logged, persisted, placed in a URL, or included in any
  error surface. Cache response bodies only.
- Four network destinations, and no others: `api.anthropic.com` (usage, with
  the OAuth token), `raw.githubusercontent.com` (LiteLLM pricing feed — plain
  GET, never any credential or account data attached; user-directed spec §10
  amendment, 2026-08-13, see README), the active provider's declared
  status feed (`status.claude.com` for Claude; §10 amendment 2026-08-19,
  v0.86.0 — anonymous conditional GET, ephemeral cookie-less session), and
  this app's own release feed (`api.github.com` releases/latest, §10
  amendment 2026-08-23, v0.87.0 — anonymous conditional GET every 6h, for
  any install whose distribution channel declares a feed: both GitHub
  flavors since v0.88.0; the release asset from `github.com`/
  `objects.githubusercontent.com` downloads exclusively on a user click).
  No analytics, no telemetry.
- A status feed is declared by `UsageProvider.statusFeed`, NOT added to
  `networkDestinations`: that list being empty is what makes a provider
  "local" (`isLocalProvider` — no budget gauge, refresh = rescan), so folding
  a status host in would silently reclassify Codex/Gemini the day they get
  feeds. The privacy card renders it on its own line.
- The account-identity source is declared by `UsageProvider.accountIdentity`
  (§10 amendment 2026-08-25, v0.89.0): a LOCAL read-only file read — for
  Claude, one key of `.claude.json` (`~/.claude.json` for the default home,
  each metered home's own copy since v0.96.0) — never a credential store,
  never a network request, never attached to anything transported. Zero
  network destinations added; the privacy card renders every path it reads,
  one line each.
- NEVER WRITE INSIDE AN AGENT HOME (`~/.claude`, `~/.codex`, `~/.gemini`
  and every metered home's own copy). Scanners are read-only by contract
  and never go near a credential file. ONE user-authorized exception
  (2026-08-14, spec §10): the Settings transcript-retention control
  writes exactly `cleanupPeriodDays` in that home's `settings.json`
  through `ClaudeCodeSettings` — read-modify-write preserving every other
  key, atomic, refusing a file whose content doesn't parse. Nothing else
  ever writes there, and a second write is a §10 amendment first.
- No App Sandbox. No entitlements we don't need.
- Never install or register anything (login items, launch agents) without
  asking the user in-session. Launch-at-login is a user-clicked toggle only.
  ONE standing exception (user-directed 2026-08-16, v0.70.0): the
  com.avihu.usaged launch agent auto-installs from the UI entry points via
  core LaunchAgentInstaller, governed by the sticky `daemonAutoInstall`
  opt-out (uninstall paths set it false; every auto-install honors it).
- Nothing outside a provider's own files may name a vendor: no
  `claude.ai` URLs, no `~/.claude` paths, no "Claude Code" strings, no
  model-id parsing. Views read `store.provider.*`. guard.sh's host
  allowlist mechanizes only the URLs — the paths and the strings are on
  you. (`docs/ARCHITECTURE.md`, the provider seam)
- Honest `User-Agent` (`claude-usage-menubar/<version>` via `AppIdentity`);
  never impersonate Claude Code or the Claude app.
- Every failure mode must render readable state. A blank or crashed menu bar
  item is a bug.
- If a permission prompt or tool denial blocks credential-adjacent work,
  surface it to the user (`!` commands) — do not route around it.
- KEYCHAIN READS GO THROUGH `/usr/bin/security` (v0.82.1):
  `KeychainCredentialSource` spawns `find-generic-password -w` instead of
  calling `SecItemCopyMatching`. Claude Code writes the item with that same
  Apple tool and REWRITES it on every token refresh, resetting the item's
  ACL grants — so native reads re-prompted per refresh no matter how stable
  our signing (the pre-v0.82.1 "constantly asks for permission" report).
  Reading as the item's own client is permanently silent. Never reintroduce
  a native SecItem read of Claude Code's item; the secret stays pipe→memory,
  never argv/logs (spec §10 unchanged: read-only, access token only).

## Where to look

| Touching… | Read first |
| --- | --- |
| the build contract itself | `docs/SPEC.md` (§10 hard rules, §12 milestones, §13 acceptance) |
| how data reaches a face, engine landing points, refresh, storage | `docs/ARCHITECTURE.md` |
| the daemon, the digest, host arbitration | `docs/DAEMON.md` |
| a provider, an account, focus, identity, storage scopes | `docs/HARNESSES.md` |
| the status item, panel, settings or sessions windows, hover/drag | `docs/UI.md` |
| any chart, the heatmap, the meter popover, the audit views | `docs/CHARTS.md` |
| the scanner, cost arithmetic, pricing, forecasts | `docs/MEASUREMENT.md` |
| `usage-cli` nouns, fields, flags, exit codes | `docs/CLI.md` |
| `tui/` | `docs/TUI.md`, then `docs/TUI-PARITY.md` |
| notices, outages, the status feed | `docs/NOTICES.md` |
| committing, merging, releasing, scripts, lint, signing | `docs/WORKFLOW.md` |
| CloudKit sync (designed, NOT shipped) | `docs/SYNC.md` |

Five targets: `UsageCore` (the headless library — every rule that says
"core" means here), `ClaudeUsage` (the app), `usaged` (the launchd host),
`usage-cli` (argv and exit codes only; the query logic is core), and
`tui/` (Rust). `ls` tells you the folders; the rules are that new code
lands in the folder matching its subject, that a file outgrowing ~600
lines splits along whole-type seams, and that
`UsageCore/AppIdentity.swift` is the one version source — the release-bump
`sed` path, and never a hand-edited Info.plist version.

## Never again

Each of these cost a user-visible bug once, and they fire in places you
may not realise you are standing. The doc named beside each says why.

- Inside a `Chart`, spell it `Color.primary` / `Color.secondary` — bare
  `.primary` resolves against the plot's foreground, i.e. the accent.
  (`docs/CHARTS.md`)
- Never re-attempt the LazyVStack message-table restructure. The lever is
  real row recycling, not SwiftUI-side diffing. (`docs/UI.md`)
- Popover anchors resolve against LAYOUT frames — position with padding,
  never `.offset`; an anchor view inserted in the transaction that flips
  `isPresented` is silently dropped. (`docs/UI.md`)
- A row whose click presents a popover needs `HoverProbe`, not
  `.onHover` — SwiftUI hover never re-enters that row afterwards.
  (`docs/UI.md`)
- A local `NSEvent` monitor precedes view dispatch, so a catcher over a
  surface that owns a horizontal scroller must carry an `enabled` flag.
  (`docs/CHARTS.md`)
- A click's event does not say where the click was: a status item's
  action reports the button's centre, so read `NSEvent.mouseLocation`.
  (`docs/HARNESSES.md`)
- Never remove the shared `NSStatusItem` — its autosave name is its
  identity, and a fresh one lands in whatever a bar manager does with new
  items. Hide it (`isVisible`). (`docs/UI.md`)
- `SMAppService.mainApp.status` is an XPC round-trip that can hang: never
  read it synchronously from a view. (`docs/UI.md`)
- Compare reset stamps through `ResetStamp`, never `Date` equality — the
  API restates `resets_at` with sub-second jitter on every poll.
  (`docs/ARCHITECTURE.md`)
- Absent ≠ zero, everywhere it is rendered or printed: an unpriced cost
  or an unreported percent is null, never 0. (`docs/DAEMON.md`)
- The digest is additive-only forever, and its goldens are decoded by
  both Swift and Rust. Regenerate only with `UPDATE_GOLDENS=1 swift test
  --filter LiveState`, then read the diff. (`docs/DAEMON.md`)
- A lookup keyed by an account takes `ProfileKey` (`.key`); only
  filesystem paths take the storage id (`.id`). A face that asks the
  digest for `default` gets the bundled harness's. (`docs/HARNESSES.md`)
- `Profile` is deliberately not `Identifiable`; every `ForEach` over
  profiles names `id: \.key`. (`docs/HARNESSES.md`)
- A field added to `Profile` must also be carried in
  `ProfileStore.resolved`, or every edit to the `default` account is
  written and then dropped on the next read. (`docs/HARNESSES.md`)
- Never predict a meter alone in the engine — `predictAll` orders
  shortest window first so lockouts resolve. (`docs/MEASUREMENT.md`)
- Renaming a meter is a data migration: history is keyed by LABEL.
  (`docs/HARNESSES.md`)
- Never poll faster than 180s (`TriggerGate.floor`) — the endpoint
  rate-limits sustained sub-3-minute polling, and adaptive cadence may
  only ever slow polling down. (`docs/ARCHITECTURE.md`)
- Every failure mode renders readable state. A blank or crashed menu bar
  item is a bug, never a degraded mode.

Rules a grep can hold are mechanized rather than remembered:
`.swiftlint.yml` `custom_rules` (headless core, native `SecItem`, key
strategies, `chartScrollableAxes`) and `scripts/guard.sh` (token-shaped
strings, signing identities, dependencies, the §10 host allowlist,
script↔task pairing). Adding a rule there beats adding a paragraph here.

## Swift practices

- Swift 6 strict concurrency: types `Sendable`, UI state `@MainActor`,
  `@Observable` for the store. No `@unchecked` without a comment proving why.
- Zero third-party dependencies — Foundation/AppKit/SwiftUI only.
- SPM package, no `.xcodeproj`. The app bundle is assembled by script;
  everything in the repo is reviewable text.
- Explicit `CodingKeys` per type; don't mix in `convertFromSnakeCase`.
- Protocol seams for testability (`CredentialSource`), value types elsewhere.
- Deployment target macOS 15.
- The app layer stays a pure function of store state, so logic that wants
  a test belongs in core.

## Testing

- Fixtures live in `Tests/UsageCoreTests/Fixtures/`, loaded via
  `Bundle.module` (subdirectory `"Fixtures"`). Real captured payloads are
  named `real-YYYY-MM-DD.json` — capture a fresh one via `mise run cli` when
  the schema drifts. Never put a real token or account identifier in a
  fixture; usage percentages and dates are fine.
- Every decode/builder behavior has a fixture test; malformed and unknown
  input must degrade gracefully, and tests prove it.
- Network behavior is tested with a `URLProtocol` stub — tests never hit the
  live endpoint.
- The credential path is NOT unit-tested; verify it live with `mise run cli`.
  Fixtures prove the renderer, not credential access — exercise the real
  path before calling a milestone done (spec §11).
- A TEST OR SCRIPT THAT SPAWNS GIT SCRUBS GIT'S DISCOVERY VARIABLES: git
  exports `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` to every hook, and
  they OUTRANK `-C`, so a throwaway-repo fixture run from a hook operates
  on the REAL repository. `SourceCheckoutProbe.gitEnvironment()` strips
  them, the `check` task unsets them, and the hook scripts `unset` them at
  the top — any new one does the same. Symptom: a stray commit, tag or
  config whose author is a fixture identity. (`docs/WORKFLOW.md`)
- `swift test` green before showing any milestone.

## Workflow

- daft-managed, contained layout: bare `.git/` at repo root, worktrees as
  siblings (`main/`). New branches via `daft start <branch>` — never
  `git worktree add`, `git checkout -b`, or in-place branch switching.
  Moving/renaming worktrees invalidates `.build` (absolute paths in the
  module cache) — `rm -rf .build` and rebuild.
- Every app/dev-lifecycle script must be runnable as a mise task — when a
  script lands in `scripts/`, a `mise.toml` task wrapping it lands in the
  same change (`mise tasks` is the catalog).
- Day-to-day: `mise run test` / `mise run cli` / `mise run build` /
  `mise run app` (rebundle + relaunch) / `mise run bundle` (no launch)
  from the worktree.
- `mise run gate` is every check the hooks, the merge gate and CI run —
  run it before showing work. Look at anything user-visible in the running
  app (`mise run app`, or the `--snapshot` PNGs), not only in tests.
- A CHANGE ARRIVES AS A PULL REQUEST, squash-merged: the PR TITLE becomes
  the commit subject on `main` and the release script reads it, so it is a
  conventional commit with the area as the scope (`fix(codex): …`). CI
  holds it to that. (`CONTRIBUTING.md`)
- NOTHING ON A BRANCH NAMES A VERSION — no bump to `AppIdentity.version`,
  no `release:` commit, no tag. The release is cut on `main` after the
  merge, by the maintainer; describe a user-visible change in
  `.release-notes/next.md` instead. Cutting, pushing and publishing a
  release are the maintainer's steps and nobody else's.
  (`docs/WORKFLOW.md`)
- The daft layout above is the maintainer's; a plain `git clone` works
  too, and then ordinary git branching is fine. daft itself is still needed
  for `check-config` (`brew install avihut/tap/daft`).
- Commit only when the person you are working for asks, or when
  structurally required (say so explicitly when it is).
