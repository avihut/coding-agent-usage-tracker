# Repository rulesets, as reviewable text

GitHub holds the live copy; these files are the record of what it should say.
Apply one with `gh` (create), or `PUT …/rulesets/<id>` to update an existing
one — `gh api repos/{owner}/{repo}/rulesets` lists the ids:

```sh
gh api -X POST repos/{owner}/{repo}/rulesets --input .github/rulesets/main-integrity.json
```

- **main: integrity** — no deletion, no force-push, linear history. NO bypass,
  the owner included: these exist to stop a slip (or an agent's), and a rule
  its only pusher can bypass stops nothing. Rewriting `main` means disabling
  the ruleset on purpose, in the UI.
- **main: merge requirements** — a PR, squash only, threads resolved, the
  `ci-gate` and `conventional-title` checks (pinned to GitHub Actions as
  their source) green on a branch that is up to date, signed commits.
  `ci-gate` is CI's roll-up (`.github/workflows/ci.yml`): it is the only CI
  check named here, so the jobs behind it can be added, split or renamed
  without touching this ruleset. The repository admin bypasses it,
  so the maintainer's local flow — `daft merge`, the post-merge release commit,
  `git push origin main vX.Y.Z` — keeps working; CI still runs on that push.
  0 approvals: a one-maintainer repo has nobody to approve the maintainer, and
  for everyone else the maintainer's merge IS the approval.
- **release tags are immutable** — a pushed `v*` tag is never moved or deleted:
  the in-app update check announces it, and a release's notes are its
  annotation. NO bypass. Re-cut a release BEFORE pushing its tag, never after.
