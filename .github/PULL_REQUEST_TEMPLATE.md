<!-- The PR TITLE becomes the squash commit's subject, and the release script
     reads it: make it a conventional commit with the area as the scope —
     `fix(codex): …`, `feat(menubar): …`. CI checks it. -->

## What and why

## How it was verified

- [ ] `mise run gate` is green locally
- [ ] Anything user-visible was looked at in the running app (`mise run app`), not only in tests

## Hard rules (CONTRIBUTING.md, docs/SPEC.md §10)

- [ ] No new network destination, no new file read outside this app's own storage, no new dependency — or the PR says which, and why
- [ ] No credential, token or account identifier in code, fixtures or logs
