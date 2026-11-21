<!-- The PR TITLE becomes the squash commit's subject, and the release script
     reads it: make it a conventional commit with the area as the scope —
     `fix(codex): …`, `feat(menubar): …`. CI checks it. -->

## What and why

## Release note

<!-- What a user will notice, in one paragraph starting with Fixes:, New: or Features: (repeat the label for a second entry), or the word none. The release notes are collected from here, so never edit .release-notes/next.md. CI checks this section. -->

## How it was verified

- [ ] `mise run gate` is green locally
- [ ] Anything user-visible was looked at in the running app (`mise run app`), not only in tests

## Hard rules (CONTRIBUTING.md, docs/SPEC.md §10)

- [ ] No new network destination, no new file read outside this app's own storage, no new dependency — or the PR says which, and why
- [ ] No credential, token or account identifier in code, fixtures or logs
