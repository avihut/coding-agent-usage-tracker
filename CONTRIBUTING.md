# Contributing

Thanks for looking. This is a one-maintainer project with strong opinions
written down; this page is the short version. The long version is `CLAUDE.md`
(the hard rules, a map of `docs/`, and the mistakes that were expensive once)
and the per-area docs it points to — read the one for the area you touch.

## Setup

macOS 15+, Xcode (Swift 6), and [mise](https://mise.jdx.dev):

```sh
mise trust && mise run setup   # pinned tools, the TUI's crates, the git hooks
mise run app                   # build + bundle + sign + launch
mise run gate                  # every check CI and the hooks run, in one go
```

No Apple developer account is needed — without a certificate the build signs
ad-hoc (README → Code signing). `mise tasks` is the catalog of everything else.

The git hooks (lefthook) format and lint what you stage, check the commit
message, and run the test suite before a push. Two of them validate
`daft.yml`, so a push — or a commit touching the hook/mise configuration —
needs [daft](https://github.com/avihut/daft): `brew install avihut/tap/daft`.
You don't need daft's worktree workflow to contribute; a plain clone is fine.

## The hard rules

These are the project's reason to be trusted with a token, and a PR that bends
one needs to say so up front (they are spec §10; most are enforced by
`scripts/guard.sh` and `.swiftlint.yml`):

- **No new network destination.** The app talks to a fixed, documented list of
  hosts. A new one is a spec amendment first and a code change second.
- **Credentials:** access token only, read fresh each cycle, never cached,
  logged, persisted or put in a URL. Never the refresh token. Never a Keychain
  write. Nothing that prompts for system credentials in regular operation.
- **Agent homes are read-only** (one documented exception). Nothing leaves the
  machine. No analytics, no telemetry.
- **Zero third-party Swift dependencies**; the TUI carries exactly four crates.
- **No real tokens or account identifiers in fixtures** — percentages and dates
  are fine.
- `UsageCore` imports no AppKit/SwiftUI; everything in it is testable headless.
- The digest (`live-state.json`) schema is additive-only, forever. CI holds a
  PR's decoders to the base branch's golden files.

## Pull requests

- **The PR title is the commit.** PRs are squash-merged, the title becomes the
  subject on `main`, and the release script reads it to choose the next
  version. Make it a conventional commit with the area as the scope —
  `fix(codex): …`, `feat(menubar): …` (never `codex: …`). CI checks it.
  Commits inside the PR are yours to shape; they're squashed away.
- **Don't touch the version.** No bump to `AppIdentity.version`, no `release:`
  commit, no tag — the release is cut on `main` after the merge.
- Optional but appreciated: describe a user-visible change in
  `.release-notes/next.md` (prose; it becomes the release notes).
- Behavior gets a test; decode/parse behavior gets a fixture test, and
  malformed input must degrade, not crash. Tests never touch the network.
- Warnings are errors. The layout of the code is deliberate — the formatter
  and linter run narrow allowlists, so please don't reformat what you didn't
  change.
- CI for a fork's PR waits for the maintainer's approval before it runs.
- **A red check names its own command.** CI runs the gate as three jobs —
  "Lint, format & repo rules" (`mise run gate-lint`), "Swift: strict build +
  tests" (`mise run gate-swift`) and "TUI (Rust): clippy + tests"
  (`mise run gate-tui`) — and `ci-gate` is green when all three are.
  `conventional-title` is the PR title check above.

## Licensing

The project is MIT licensed. By contributing you agree your contribution is
licensed under the same terms (GitHub's inbound=outbound rule).

## Security

Not in an issue, please — see [SECURITY.md](SECURITY.md).
