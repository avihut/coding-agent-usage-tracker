# Workflow: gates, hooks, releases, distribution

How work lands: the git hooks and daft's merge gate for the maintainer's
own merges, and CI running the same `mise run gate` for pull requests.

**Read this before** committing, merging, releasing, adding a script, or
changing a lint rule.

Every check is a mise task that both lefthook and daft call — one
definition each. `mise run gate` is the whole set by hand; run it before
showing work.

## Hooks and the merge gate

- HOOKS AND THE MERGE GATE (2026-09-19): git hooks are lefthook
  (`lefthook.yml`), the merge gate is daft (`daft.yml` `merge:` +
  `pre-merge`/`post-merge`), and EVERY check is a mise task both call — one
  definition each; `mise run gate` is the whole set by hand, run it before
  showing work. CI (`.github/workflows/ci.yml`, since 2026-09-20) runs that
  same `gate` plus `digest-freeze` for pull requests — it exists because a
  merge made with GitHub's button never meets daft's rings; the local gates
  stay the ones the maintainer's own merges pass through. pre-commit
  (staged files, sequential — formatters rewrite what the linter reads
  next): `fmt-swift`, `fmt-rust`, `git diff --cached --check`,
  `lint-swift`, `lint-shell`, `check-config`, `guard`.
  commit-msg: conventional commits via `cog verify` (`cog.toml` adds this
  repo's `release` type; an AREA IS A SCOPE — `feat(menubar): …`, never
  `menubar: …`), a `release:` subject is exactly `release: vX.Y.Z` and must
  equal the staged `AppIdentity.version`, and a commit that moves the
  version must BE that release commit. pre-push: `check`, `tui-clippy`,
  `tui-test`, `test-hooks`, `check-config`, `release-check` (a pushed
  release commit has an ANNOTATED `vX.Y.Z` tag on that very commit —
  publish.sh reads the annotation as the release notes). Push with `daft push`, so the hook runs in the pushed
  branch's own worktree. WARNINGS ARE ERRORS, NEVER GREPPED: an incremental
  `swift build` re-emits nothing for a file it doesn't recompile, so a
  no-op build prints zero warnings whatever the tree holds; `check` is
  `swift test -Xswiftc -warnings-as-errors` (all targets + tests + the
  suite) in its OWN scratch path `.build/strict` — a changed `-Xswiftc`
  flag invalidates the cache, and sharing `.build` would make `check` and
  `mise run app` rebuild the world on each other's heels (~38s cold,
  seconds warm, ~290MB per worktree). Every build/test task also runs
  under `scripts/no-warnings.sh`, which fails a command that exited 0 but
  printed `warning:` — the linker, SwiftPM and cargo warn outside the
  compiler flags' reach — and `check` unsets `UPDATE_GOLDENS`, so a gate
  can never become a golden WRITER. The pattern it caught on day one,
  seven times: an outer Timer/`onChange` closure capturing `self` strongly
  around a `Task { [weak self] … }` — the `[weak self]` belongs on the
  OUTER closure, or a repeating timer keeps its owner alive.
  LINT/FORMAT ARE OPT-IN ALLOWLISTS, because this codebase's layout is
  hand-made on purpose: SwiftLint's defaults are 956 style/size findings
  and SwiftFormat's would rewrite 230 of 249 files. `.swiftlint.yml` =
  twenty correctness rules + `custom_rules`, the home of this file's
  greppable "never again" rules for Swift source (headless core, native
  SecItem calls, key strategies, `chartScrollableAxes`) — add the next one
  THERE; `Tests/.swiftlint.yml` lifts `force_try`/`force_cast`.
  `.swiftformat` = whitespace hygiene only; `modifierOrder`,
  `redundantNilInit` and `todos` were tried and rejected after reading
  their diffs (the last mangled `// MARK: --relative`) — read a rule's
  whole-tree diff before enabling it. `scripts/guard.sh` holds the rules
  that aren't Swift source: token-shaped strings, signing identities,
  package/crate dependencies, the §10 HOST ALLOWLIST (every host `Sources`
  and `tui/src` name — a new host is a §10 amendment first, then a line
  there), script↔mise-task pairing. The app scripts are zsh, which
  shellcheck cannot read (SC1071): `lint-shell` gives them `zsh -n` and
  shellcheck the hook scripts, which are bash for that reason (and
  3.2-safe — macOS's own: no apostrophe inside a `${VAR:?message}`, 3.2
  reads it as an unterminated quote — `test-hooks` caught that one).
  THE HOOK SCRIPTS HAVE TESTS: `scripts/test-hooks.sh` (`mise run
  test-hooks`, 71 checks, in pre-push and the merge gate) drives every
  script through its pass AND refusal paths in a throwaway repo under
  `.build/` — a new hook script or rule lands with its cases there. MERGE
  (squash-first since 2026-09-20): `daft.merge.style = squash` — a git
  config, since daft.yml has no key for the STYLE, which is why a personal
  global `squash` once overrode a repo that declared `ff: only` and left a
  squash staged on main that no commit message could land. `ff: only` is
  GONE from daft.yml (a squash can never fast-forward), and the half of it
  worth keeping — the branch already contains the target's tip, so the
  tested tree is the landed tree — is the `source-up-to-date` pre-merge
  ring. Rebase, then `daft merge <branch> --into main -F <message>`: ALWAYS
  pass `-m`/`-F`/`--no-edit`, because a squash opens an editor and an empty
  message is git's own refusal, before any hook, leaving the same staged
  limbo. `source_worktree: clean` stays; rings run in the SOURCE worktree,
  `glob` skips a toolchain the merge never touched, `--skip-tag deep` drops
  the release build (deliberately NOT `mise run bundle`: bundle.sh replaces
  `AgentUsage.app`, possibly the live install's). THE DIGEST FREEZE is
  the one check only a merge can make: the golden is regenerated in place,
  so on any branch code and golden agree and a breaking change +
  `UPDATE_GOLDENS=1` passes both suites — `scripts/digest-baseline.sh`
  exports the TARGET's goldens, and `DigestFreezeTests` + the Rust
  `baseline_goldens_decode` (both inert without `DIGEST_BASELINE_DIR`)
  require that this tree's decoders read them and that every key path they
  carry is still in the current golden (`mise run digest-freeze` by hand).
  The `incoming-commits` ring (`cog check target..HEAD`) catches
  subjects written with `--no-verify`. post-merge (warn-only): the landed
  tree is the gated tree, and unreleased `feat`/`fix` on main prints the
  release ritual. SETUP is `mise run setup` (pinned tools, `cargo fetch
  --locked`, `lefthook install`), cached on its sources; daft's
  post-create, mise's `enter` hook and its `watch_files` all call it.
  Hooks install into the bare repo's SHARED hooks dir, and the launcher
  resolves lefthook as `mise exec -- lefthook` (`lefthook:` in
  lefthook.yml), so hooks run from shells that never activated mise; a
  worktree whose branch has no `lefthook.yml` prints a one-line notice and
  proceeds. mise's `arg()` task templates are deprecated (gone in mise
  2027.5): take arguments through a task's `usage` field, or rely on mise
  appending them to the LAST command of `run`.

## The day the hooks landed: git's discovery variables

- A TEST THAT SPAWNS GIT SCRUBS GIT'S DISCOVERY VARIABLES (2026-09-19, the
  day the hooks landed): git exports `GIT_DIR`/`GIT_WORK_TREE`/
  `GIT_INDEX_FILE` to every hook — always, in this bare-repo-plus-worktrees
  layout — and they OUTRANK `-C`. The pre-push hook runs the suite, so
  `SourceCheckoutProbeTests`' throwaway-repo fixture (`git -C <tmp> init /
  config / commit / tag`) ran against the REAL repository instead: a commit
  "one" by `Test <test@example.com>` on main, a lightweight `v1.2.3` tag,
  and `user.name = Test` written into the shared config (which would have
  re-authored every later commit in every worktree). Nothing reached
  origin. Two layers now: `SourceCheckoutProbe.gitEnvironment()` strips the
  variables for the probe's own reads AND the fixture (unit-tested), and
  the `check` task unsets them before `swift test`. Any new test or script
  that shells out to git does the same — the hook scripts `unset` them at
  the top. Symptom to recognize: a stray commit/tag/config whose author is
  a fixture identity.

## The release ritual

- RELEASE RITUAL — a shipped feature or fix is NOT done until it is
  released, in the same session (a fresh session on 2026-09-03 committed
  two changes and stopped, because nothing had written this down; every
  install stayed behind). THE RELEASE IS A SIDE-EFFECT OF THE MERGE, NOT
  ITS INTENT (user-directed 2026-09-20: "the merge's intent is to bring in
  new code, the side-effect is to issue a release"). So NOTHING ON A BRANCH
  NAMES A VERSION — no bump, no `release:` commit, no tag — and therefore no
  merge ever carries a version move, which is what stops `commit-msg.sh`'s
  "a commit that moves the version must BE the release commit" from applying
  to merges at all. It used to be prepared by hand on the branch; that
  coupled the release to the merge's INPUT, so a squash had to be named
  `release: vX.Y.Z` and the branch's tag stayed behind on a commit that
  never landed.
  A branch instead writes `.release-notes/next.md` — prose, gated like any
  other file, because the annotation IS the GitHub release notes and a list
  of commit subjects is a visible downgrade. On merge, daft's post-merge
  `release` job (`mise run release`, scripts/release.sh) reads the
  conventional commits since the last tag (minor for `feat`, patch for
  `fix`, nothing otherwise; pre-1.0 a `!` is a minor, never an automatic
  1.0.0), stamps `AppIdentity.version` — the ONE version source, Info.plist
  is stamped from it — commits `release: vX.Y.Z` with those notes, spends
  the fragment in the same commit, and annotates the tag. It is idempotent:
  a tip that is already `release: vX.Y.Z` only gets its missing tag, which
  is how a branch cut under the OLD ritual still lands correctly.
  IT NEVER PUSHES. Reading the release and then (1) `git push origin main
  vX.Y.Z`; (2) `mise run publish` — the GitHub release from the tag's notes,
  NO binary (see Distribution); installs see it on their next 6h check and
  say "pull and rebuild" — stay a human step, and `release-check`
  (pre-push) is the backstop if the hook ever leaves a release half made
  (post-merge warns, never rolls back). Tags and commits GPG-sign by config,
  so a locked agent makes the job warn rather than release; `mise run
  release` by hand finishes it.

## Signing

- Binaries are signed via `scripts/sign.sh` BEFORE first run with a
  MACHINE-LOCAL identity — NO developer account is named anywhere in the
  repo (2026-09-03; a second contributor's clone failed on the old
  hardcoded certificate). Resolution: `CODESIGN_IDENTITY` (per-checkout via
  git-ignored `mise.local.toml`, example file committed) > keychain
  auto-discovery (Developer ID Application > Apple Development > Mac
  Developer) > ad-hoc with a warning. `mise run identity` shows the
  resolution. Ad-hoc is acceptable for a dev build (the Keychain read
  needs no stable signature since v0.82.1) but `dist.sh` sets
  `CODESIGN_REQUIRE_IDENTITY=1` and refuses it — never ship an ad-hoc
  build. Never reintroduce a hardcoded identity, name, or team ID.

## Distribution and self-update

- RELEASES CARRY NO BINARY (2026-09-20, maintainer's decision: without a
  paid Developer ID and notarization, "download it, compile it with your own
  ID, and run it"). An Apple Development signature is one Gatekeeper REJECTS
  on any other Mac (`spctl -a` on the v0.100.1 zip: rejected), so the 31
  zips published from v0.87.1 to v0.100.1 were removed and `mise run
  publish` now creates the release from the tag's annotation alone
  (`%(contents:subject)` + `%(contents:body)` — `%(contents)` carries the
  GPG signature block, and every earlier release's notes ended in one). The
  release still matters: it is the feed the update check reads. `mise run
  dist` survives as a private tool for carrying a build to another Mac of
  one's own. The one-click pipeline below is DORMANT, not deleted — with no
  asset nothing offers it (`store.canSelfInstall(update)`; a standalone
  install's card says to rebuild from source instead). It checks WHOSE
  signature a download carries, not only that it is intact: `SignerPin`
  (core) requires the bundle to satisfy the running app's own designated
  requirement — `codesign --verify` alone passes an ad-hoc re-sign. An
  ad-hoc install can therefore vouch for nothing and never self-updates,
  and a changed bundle id or certificate fails the same way: by design, the
  way through is a rebuild. `--fake-asset` beside `--fake-update` shows the
  one-click presentation. Info.plist versions are STAMPED from AppIdentity.swift by
  bundle.sh/dist.sh — never hand-edit them (they drifted two releases behind
  when hand-maintained, and the updater verifies downloads by that key).
- DISTRIBUTION CHANNELS (v0.88.0, user-directed "think of it as
  distribution streams"): every install auto-resolves to a channel
  (`Distribution.channel`, UsageCore/Update/DistributionChannel.swift) that
  owns its whole update story — feed URL, whether one-click install may
  run, and the manual hint when it may not. Today's one channel is
  `GitHubChannel` with two flavors off `InstallKind`'s ancestor walk:
  `.releaseInstall` (standalone bundle, full pipeline) and
  `.sourceCheckout(root:)` (`mise run app` build — polls the SAME feed but
  only informs: pull-and-rebuild hint, never the swap). All the ugly
  install forensics stay inside the channel + `SourceCheckoutProbe`
  (LOCAL-ONLY `git rev-parse` — branch, short sha, is-the-tag-pulled;
  NEVER networked git, which would spend user credentials outside §10's
  destinations). A future store channel returns nil `updateFeedURL` and
  every update surface goes dark. Presentation follows
  `store.updateCanSelfInstall`; `AppUpdater.install` carries the same
  guard as a belt (`Distribution.allowsSelfInstall`), and the drill's
  `updateFeedURL` override forces install-mode through both — the drill's
  staged bundle sits inside the checkout by construction.
- The engine's `UpdateChecker` (UsageCore/Update/) polls
  `api.github.com/repos/avihut/coding-agent-usage-tracker/releases/latest`
  every 6h (conditional GET, honest UA — GitHub refuses UA-less requests)
  and publishes `LiveState.appUpdate`. It runs whenever the install's
  channel declares a feed — both GitHub flavors, so the dev worktree now
  shows the card too (as manual guidance). A failed check keeps the last
  card; only a definitive 404 withdraws it. `AppVersion` compares dotted
  ints; unparseable is NEVER newer.
- UI is deliberately a whisper: an accent `arrow.down.circle.fill` beside
  the footer's version label, an "Update to X…" ⋯-menu item, and a
  Settings → General card (install / Check Now / auto-check toggle / skip
  version via `updateSkippedVersion`; a Distribution identity row names
  the channel + checkout coordinates). On a non-installing flavor the
  arrow and menu item open Settings instead, where the card carries the
  pull-and-rebuild hint (sharpened to "just rebuild" when the release tag
  is already local). No menu-bar change, no notifications. A face whose
  own version already equals the card's stays quiet — the daemon lags one
  relaunch behind right after an update.
- One click runs `AppUpdater` (App/AppUpdater.swift): download (host
  allowlist github.com/*.githubusercontent.com), `ditto -xk`, `codesign
  --verify --deep --strict`, plist version must MATCH the clicked release,
  stage beside the bundle (same volume), two-rename swap with rollback,
  `launchctl kickstart` the daemon, detached-shell relaunch. Downloads by
  the app carry no quarantine (no LSFileQuarantineEnabled), so Gatekeeper
  doesn't re-interrogate updates.
- Verify UI with `--fake-update <version|current>` (no asset URL — a click
  on the fake opens the releases page, never swaps) plus
  `--fake-channel <release|source>` to force the OTHER flavor's
  presentation on whichever flavor the machine actually is. Drill the real
  pipeline against a localhost feed via the `updateFeedURL` defaults
  override, which forces both the checker and install-mode on in a source
  build.


## The app icon

- THE RENAME (0.102.0, 2026-09-20, maintainer-directed: "the app name should
  be changed to AgentUsage […] any change that needs to be done to support
  it needs to happen"): the app was `ClaudeUsage.app` / `com.avihu
  .ClaudeUsage` / launch agent `com.avihu.usaged` / package and User-Agent
  `claude-usage-menubar`; it is `AgentUsage.app` / `io.github.avihut
  .AgentUsage` / `io.github.avihut.usaged` / `coding-agent-usage-tracker`
  (the repository's name). `AppIdentity` holds all of them — `bundleID`,
  `daemonLabel`, and the two `legacy…` constants that ONLY
  `IdentityMigration` and `LaunchAgentInstaller.retireLegacy` may read; no
  other literal of either id exists in Swift (the TUI has its one Rust
  constant), and AppIdentityTests holds Info.plist to the same value. A
  BUNDLE ID IS A DATA MIGRATION: `IdentityMigration` (core, Storage/) runs
  FIRST in the app and in usaged — before `StorageMigration`, whose lock file
  would create the new root, and before usaged's installer verbs, which read
  the sticky `daemonAutoInstall` out of the very defaults being carried. Its
  order is the design: retire the old agent → wait (bounded) for the old
  engine's lease → MOVE the Application Support and Caches roots
  (`rename(2)`; an entry the new root already holds is never overwritten,
  the old copy stays) → carry defaults keys the new domain lacks (AppKit's
  status-item positions ride along) → marker LAST, so an interrupted run
  retries. The app first asks a running copy of the old bundle id to quit
  (the one AppKit piece). Readers — `usage-cli`, the TUI — never migrate.
  NOT carried, because they belong to a bundle id: the login item
  (`SMAppService` — switch it on again) and whatever a menu bar manager
  remembered about the old status item (the v0.97.2 lesson, this time
  unavoidable). `bundle.sh` deletes a stale `ClaudeUsage.app` beside the new
  bundle: it is still a launchable app under the old id, and one launch of
  it re-creates the old directories. Goldens and captured fixtures keep
  their `ClaudeUsage-<version>.zip` asset names — they are records of real
  releases, not names of this app. `SignerPin` will refuse a one-click
  update ACROSS the rename (the designated requirement names the old
  identifier) — moot while releases carry no binary, and correct anyway.
- OPEN SOURCE (2026-09-20, after the first outside PR): MIT `LICENSE`,
  `CONTRIBUTING.md`, `SECURITY.md` (private vulnerability reporting),
  Dependabot with a 7-day cooldown. WORKFLOWS are hardened on purpose —
  `pull_request` and NEVER `pull_request_target`, read-only token, every
  action pinned to a commit SHA (a repo setting refuses anything else), no
  event text interpolated into a shell line, fork PRs wait for approval, and
  NO SECRET EXISTS to steal: CI never signs, bundles or publishes. RULESETS
  live as text in `.github/rulesets/` (README there): main's integrity rules
  and the tag immutability rule have NO bypass, the maintainer included — a
  pushed `v*` tag never moves, so re-cut a release BEFORE pushing it; the PR
  gate is bypassed by the repository admin so `daft merge` + `git push
  origin main vX.Y.Z` keeps working. A PR LANDS by GitHub's squash button
  (the contributor gets a merged PR; a local `daft merge` would leave it
  "closed"), its TITLE is the commit subject (`pr-title.yml` holds it to
  `cog verify` and refuses `release:`), then on main: `git pull`, `mise run
  release`, push, publish. release.sh wants a CLEAN worktree and, with no
  fragment, annotates with the merged subjects — so for prose notes, push
  `.release-notes/next.md` onto the PR branch BEFORE merging (maintainer
  edits are allowed on fork PRs), never as a dirty file on main.
- The app icon (the "cursor fuel" mark — mint prompt chevron, block cursor
  charged yellow→orange to the budget left) has NO checked-in asset:
  `scripts/icon.swift` draws it in CoreGraphics (512-pt design space mapped
  onto Apple's 824-pt grid; ≤32 px renders simplify — heavier chevron, no
  baseline). `scripts/icon.sh` (`mise run icon`) caches the `.icns` at
  `.build/icon/AppIcon.icns`, regenerating only when the renderer changes;
  `bundle.sh`/`dist.sh` copy it into `Contents/Resources` and
  `CFBundleIconFile` points at it. Changing the mark = editing the renderer.
