# Plan: release notes come from PR descriptions, not a shared file

Branch `chore/release-notes-from-prs`. Why (user-directed 2026-11-22): every
PR appended to `.release-notes/next.md`, so every merge conflicted with every
other open PR. The rule is already in force for workers (no PR edits
`next.md`; each PR carries `## Release note` in its description). This makes
it the project's way, for outside contributors too: the release script
collects the notes, the template asks for them, CI requires them, the docs
say so.

## What exists (read before planning)

- `scripts/release.sh`: post-merge side-effect (daft.yml) and `mise run
  release` by hand. Decides the bump from conventional subjects since the
  last `v*` tag, writes `release: vX.Y.Z` with the notes as its body, resets
  `next.md` to the template in the same commit, annotates the tag from the
  same text. Notes today = `next.md` minus its HTML comment, else a list of
  subjects. `--dry-run` prints only the verdict. Never pushes.
- `publish.sh` ships the tag's subject + body as the GitHub release notes;
  `release-check.sh` (pre-push) holds release commit ↔ annotated tag. Both
  stay untouched: the annotation is still one text, assembled earlier.
- `.github/workflows/pr-title.yml`: `conventional-title`, triggered on
  `opened, edited, reopened, synchronize` — `edited` is what re-runs a check
  when the DESCRIPTION is edited, so the new check lives in this workflow,
  not in `ci.yml` (which doesn't run on `edited`, and whose jobs guard.sh
  holds to `ci-gate`'s `needs`).
- `.github/PULL_REQUEST_TEMPLATE.md` already exists (upper case) — extend it;
  a second, lower-case template would compete with it.
- Merged since v0.103.0: #32–#44 + two direct commits (`1e92ff4`,
  `d4a1948`). None of those PR bodies has a `## Release note` section (checked
  with `gh`), so the first release after this change cannot double-count:
  their notes are the legacy entries already in `next.md`. Open #45 has one;
  its body ends with an attribution footer and a session link right after
  the entry, with no heading between — the parser must stop before those.

## Design

### 1. `scripts/release-notes.sh` (new, bash, 3.2-safe) + mise task `release-notes`

One grammar, read by both release.sh and CI, so a description the check
passes is a description the release can read. PLAIN BASH, no awk/sed in
the parsing: `while IFS= read -r` + `case` globs under `shopt -s
nocasematch`. Bash implements glob matching itself, so the grammar behaves
the same on the Ubuntu runner (bash 5, mawk) as on a Mac (bash 3.2, BSD
awk) — the CI check is never exercised by test-hooks on Ubuntu, so it must
not depend on the platform's awk or regex library. `—`/`–` are matched as
alternatives (`*'—'*|*'–'*`), never inside a bracket expression, and a case
runs under `LC_ALL=C` (hooks may have no UTF-8 locale). Every value is
quoted and printed with `printf '%s'` — PR bodies are outsiders' text.

```
release-notes.sh check            PR description on stdin; exit 0 when it has a usable
                                  ## Release note (entries or `none`), else 1 with the reason
release-notes.sh entries          PR description on stdin → one "<fixes|features><TAB><text>"
                                  line per entry; exit 0 (entries or none) / 1 (no section) /
                                  2 (a section that says nothing usable)
release-notes.sh commit-entries   commit message on stdin → the same lines, from
                                  "Release note — <Label>: …" paragraphs
release-notes.sh assemble <range> <fallback subject>
                                  next.md + every commit in <range> → the notes on stdout,
                                  warnings on stderr; exit 1 when a description cannot be
                                  read or its note is malformed
```

**PR-description grammar** (`entries` / `check`):
- `\r` stripped first (descriptions edited on github.com arrive CRLF); HTML
  comments stripped (the template's hint lives in one); headings inside
  ``` fences ignored.
- The section is the first heading `#…# Release note` / `Release notes`
  (any level, case-insensitive, optional trailing colon), up to the next
  heading.
- `none` (any case, optionally `.`/emphasis-wrapped) as its first paragraph
  → no entries, check passes.
- An ENTRY starts on a line beginning with a label — `Fixes:` / `Fix:` →
  fixes; `New:` / `Features:` / `Feature:` → features — tolerating `**…**`
  and a leading `- `. Following non-blank lines continue it. A label with
  nothing after it followed by `- ` bullets gives one entry per bullet.
- The note ENDS at a blank line followed by a paragraph that doesn't start
  with a label (the attribution footer, links, anything else) or the next
  heading. So: one paragraph per entry; repeat the label for a second one.
- Missing section → exit 1 ("no ## Release note — write one, or `none`").
  Section present but empty, or prose with no label → exit 2 (the reason
  names the three labels).

**Commit grammar** (`commit-entries`): a paragraph starting `Release note`
then `—`, `–`, `--`, `-` or `:`, then a label, e.g. `Release note — Fixes:
the daemon no longer …` (the form the brief names). `Release note: a Fixes
entry in next.md` (#39's prose) does not match: after the separator comes a
word that isn't a label.

**`assemble`**:
1. `git log --reverse` over the range: a subject ending in `(#N)` is PR #N
   (GitHub's squash convention) → its description via `gh pr view N --json
   body --jq .body`, or, when `RELEASE_NOTES_PRS=<file.json>` is set, from
   that JSON array of `{number, body}` (the shape `gh … --json number,body`
   prints; read with `jq`, which macOS ships in `/usr/bin` since 15). With
   the variable set, gh is never called — that's how test-hooks stays
   offline. Any other commit → its message via `commit-entries`.
2. Problems: gh missing, or failing for any reason but "not a PR" (network,
   auth) → error (exit 1, names the PR and gh's message). gh's `Could not
   resolve to a PullRequest` (a subject ending in an ISSUE number, or a PR
   of another repo), and a number absent from the fixture, are not errors:
   that commit is read as a direct one (`commit-entries`) with a warning, so
   an issue reference can never block a release. A malformed note (exit 2) →
   error naming the PR and "fix its description (`gh pr edit N`), then: mise
   run release". A MISSING section on a `feat`/`fix` subject → a warning
   only (every PR before this change is like that, and its note is a legacy
   `next.md` entry); on other types → silent (dependabot's `chore` bumps).
3. Merge with `next.md` (comment stripped, as today): line 1 is the tag
   subject; then the maintainer's prose; then sections. A heading is a line
   that is just `Fixes` / `New` / `Features` (optionally `#`-prefixed or
   `:`-suffixed). Each collected entry is appended to the END of the
   matching section (legacy entries first, then PRs in merge order), and a
   section `next.md` lacks is appended after the others, headed and ordered
   as `next.md` does today: `Fixes`, then `Features`. `New:` and
   `Features:` are one section; its heading is whichever of the two
   `next.md` already has.
4. Entries render as `next.md`'s bullets do: `- ` + text with its first
   letter capitalised (labels are followed by lower case: "Fixes: the
   daemon…"), word-wrapped at 76 columns (`fold -s`, assembly only — it runs
   on the maintainer's Mac, never in CI) with a two-space hanging indent.
   The text is otherwise verbatim: backticks, `%`, `\`, `$(…)`, `*` survive.
5. Empty `next.md` + entries → subject `v<next>` (v0.100.1's precedent), with
   a line saying so. Empty `next.md` + no entries → today's list of subjects.

### 2. `scripts/release.sh`

- Notes = `release-notes.sh assemble "$range" "v$next"` instead of
  `written_notes`; an exit 1 refuses the release (post-merge is warn-only,
  so the merge stands; the fix is the PR description, then `mise run
  release`). Everything else — bump decision, one commit, template reset,
  tag, never pushing, the already-a-release-commit path, the GPG-locked
  rerun reading the release commit's own body — unchanged.
- `--dry-run` assembles and PRINTS the notes (it used to stop at the
  verdict), and exits 1 where the real run would refuse. Because it writes
  nothing, it also runs off main and on a dirty tree ("preview any time" —
  above all while the maintainer is editing `next.md`); the real run keeps
  both refusals.
- The template it writes back gets the new header (below).

**How the maintainer's title and prose reach `next.md` now** (WORKFLOW.md
used to say "push `next.md` onto the PR branch before merging"; that goes):
the maintainer COMMITS `next.md` on main — it is their file, PRs never touch
it, so it conflicts with nothing — any time before the merge or the `mise
run release` that cuts the release (`docs(release): …`, no bump). Preview
first with `--dry-run`, which reads the edited, uncommitted file. No code
change: the real run keeps refusing a dirty tree. With nothing written, the
release still cuts, titled `vX.Y.Z`, with every PR's entries. If the
post-merge hook cut one that way and the maintainer wants a title, before
anything is pushed: `git tag -d vX.Y.Z && git reset --hard HEAD~1` (drops
the unpushed release commit), commit the title in `next.md`, `mise run
release`. After a push the tag is immutable (ruleset) — re-cut BEFORE.

### 3. `.release-notes/next.md` — header comment only

Entries untouched. The comment says: the MAINTAINER's file (title + prose
written by hand); pull requests never edit it — a change describes itself
under `## Release note` in its PR description and release.sh collects it;
the first line is the tag's subject. Line 1 of the file stays byte-identical
(common.md: "never touch its first line"); release.sh's template is the same
text.

### 4. `.github/PULL_REQUEST_TEMPLATE.md`

A `## Release note` section between "How it was verified" and "Hard rules",
with a one-line hint in an HTML comment (stripped by the parser, so an
untouched template fails the check with "empty"): "What a user will notice:
one paragraph starting `Fixes:`, `New:` or `Features:` — or `none`."

### 5. CI: `release-note` job in `pr-title.yml`

Beside `conventional-title`, same triggers (so editing the description
re-runs it), `ubuntu-latest`, checkout without credentials, no mise (bash +
awk only). The body arrives through `env:` (attacker-controlled text, never
interpolated) → `printf '%s' "$PR_BODY" | scripts/release-notes.sh check`.
Dependabot's PRs (author login `dependabot[bot]`, a GitHub-controlled value)
pass with a notice: a bump cuts no release and its body is Dependabot's.
The parser is plain bash (§1), so the runner's mawk never matters;
test-hooks' parser cases are also run by hand under `/bin/bash` 3.2 and
bash 5 before the PR.

Workflow `name:` becomes "PR title and release note"; file name unchanged
(docs reference it).

**Required check — THIS CHANGES THE MERGE GATE, flagged at the top of the
PR**: `.github/rulesets/main-merge-requirements.json` (the reviewable
record) gains `release-note`; its README and the dependabot-auto-merge
comment name it. APPLYING it to GitHub is the maintainer's step (an account
action, not mine). Until applied the check is advisory (red, not blocking).
Once applied, every open PR needs the section before it can merge —
including the OUTSIDE PRs #1 and #22, whose authors (or the maintainer, via
an edit) must add it; #42 and #45 are workers'. The checks appear on a PR's
next push or description edit.

### 6. Docs

- `docs/WORKFLOW.md` → release ritual: the note lives in the PR
  description; release.sh collects, groups, merges with the maintainer's
  `next.md`; the grammar; `--dry-run` as the preview; a local `daft merge`
  of a branch with a PR must end its subject in `(#N)` for the note to be
  read. The OPEN SOURCE bullet's "push next.md onto the PR branch before
  merging" goes. test-hooks' check count updated.
- `CONTRIBUTING.md`: the "optional next.md" bullet → "every PR's description
  has a `## Release note` (or `none`); CI checks it"; `release-note` beside
  `conventional-title` in the red-check bullet.
- `CLAUDE.md`'s Workflow line → the PR description, never `next.md`.
- `mise.toml`: `release-notes` task; `release`'s description.

### 7. Optional, small, FIRST TO CUT: a guard tripwire

Every required check named in `.github/rulesets/main-merge-requirements.json`
is a job some workflow defines. A required check no workflow reports leaves
every PR "Expected — waiting" forever, and renaming `release-note` would do
exactly that. ~10 lines + a test-hooks trip. Built last; dropped if the
build runs long.

## Assumed (decisions taken without asking)

- The grammar's labels: `Fixes:`/`Fix:` and `New:`/`Features:`/`Feature:`
  (two sections). Headings and order for sections `next.md` lacks: `Fixes`
  then `Features`, as `next.md` has them today.
- One paragraph per entry; the note ends at the first unlabeled paragraph
  (that is how #45's footer stays out).
- A MISSING section warns (feat/fix only); a malformed one, or an
  unreadable description, refuses the release. An issue number in a
  subject falls back to the commit message.
- Titles: the maintainer commits `next.md` on main; no dirty-tree
  exception in the real run. Fallback subject `vX.Y.Z`.
- `--dry-run` runs off main and on a dirty tree, and exits 1 where the real
  run would refuse.
- The existing upper-case `.github/PULL_REQUEST_TEMPLATE.md` is extended
  (GitHub reads either case; two would compete).
- The CI job lives in `pr-title.yml` (it already triggers on `edited`);
  dependabot exempt by author login.
- `release-note` goes into the ruleset RECORD as required; applying it is
  the maintainer's.
- `next.md`'s line 1 stays byte-identical; only lines 2+ of its comment
  change.
- The plan is kept on the branch (`docs/plans/`), as the other features'
  are.

## Verify

- `scripts/test-hooks.sh`, new cases (pass AND refusal paths, offline): a
  STUB `gh` first on PATH for the whole file, failing loudly, so nothing
  can reach the network (it answers "Could not resolve to a PullRequest"
  for one number and a connection error for the rest). Parser — an entry;
  `none`; no section (1); empty section / template hint only (2); unlabeled
  prose (2); CRLF; two labels; label + bullets; the attribution footer
  excluded; a fake heading inside a fence ignored; one case under
  `LC_ALL=C`. Commit grammar — `Release note — Fixes: …` read; `Release
  note: a Fixes entry…` not. Assembly through `release.sh --dry-run` in the
  fixture repo with `RELEASE_NOTES_PRS`: legacy `next.md` entries kept and
  first, PR entries grouped under them in merge order, a `Features` section
  created after `Fixes`, `none` contributes nothing, a missing section
  warns, a direct commit's note included, wrapping/capitalisation, a
  HOSTILE entry (backticks, `%`, `\`, `$(…)`, `*`) verbatim in the
  annotation; dry-run on a dirty `next.md`; refusal for a malformed note
  and for gh failing (no fixture → the stub's connection error); an issue
  number (the stub's "not a PR", and a number absent from the fixture)
  falls back with a warning; then a real run in the fixture: annotation ==
  assembled notes, `next.md` reset to the new template.
- By hand: `RELEASE_NOTES_PRS=<fixture with #45's real body> scripts/release.sh
  --dry-run` in this worktree (writes nothing; shows today's `next.md` plus
  #45's entry), and once with real `gh` (read-only) to see the legacy
  warnings the first release will print.
- The CI step's shell lines run locally with a body with and without the
  section, and as dependabot.
- `mise run gate` green.
- Never a real release, tag or publish.

## Found (belongs elsewhere)

- `scripts/release-reminder.sh` still prints the pre-2026-09-20 manual ritual
  (bump, commit, tag by hand) where `mise run release` is the step now.

## Changed while building (2026-11-22)

- **The note is read from the squash commit first.** An automated security
  review of the first build pointed out that a description stays editable
  after its merge, so `gh pr view` at release time would carry an author's
  later edit, never reviewed, into the tag. GitHub's squash commits on main
  carry the PR description as their body (#37–#44 all do), so `assemble`
  reads the note from there: frozen as merged, and offline. The live
  description, through gh or the fixture, is the fallback only when that
  body has no usable note (a hand-written merge message, a local merge),
  and its entries are flagged "review before pushing".
- **A pre-existing release.sh bug, fixed here.** The bump test piped the
  range's log into `grep -q` under pipefail. Once the log outgrew the
  pipe's buffer (squash bodies are whole descriptions: v0.103.0..main is
  114 KB), grep's early exit SIGPIPE'd the printf, and a range full of
  feat and fix read as "nothing releasable". The next real release on main
  would have hit it. Here-strings now; test-hooks pushes a 128 KB log
  through it.
- The template's section sits after "What and why", where the change is
  still in mind.
- Guard rule 7 (§7) was built: 3 checks in test-hooks.
- Checked against what really landed (`assemble v0.103.0..origin/main`,
  read-only, after #45 and #42 merged): #45's note read FROZEN from its
  squash body (re-wrapped at 72, signature and trailer block after it),
  once; #42's squash body is an older revision of its description with no
  section, so its four entries were read LIVE and flagged, once each. The
  squash-merge message setting is `PR_BODY` (a read-only `gh api` GET).
- Rewording a frozen entry is an edit of the annotation before pushing
  (`git tag -f -a vX.Y.Z` opens it pre-filled); tested with release-check.
- A live-read failure refuses only for feat/fix subjects; anything else
  (Dependabot's chores) warns, so an offline release isn't blocked by them.

## Review round (2026-11-22, two Opus reviewers)

- **The squash copy is NOT the merged text** (CI/docs reviewer, verified on
  #42): GitHub fixes the squash message when the merge is set up — for
  auto-merge, when it is ARMED. #42's squash body is the 22:27 revision; the
  note was added at 23:28 and it merged at 23:50. Reading the squash copy
  first would ship a stale-but-valid note CI never saw. So the note is now
  the description AS IT STOOD AT THE MERGE: live (GraphQL `body`,
  `lastEditedAt`, `mergedAt` through `gh api graphql`), unless edited after
  the merge — then the squash copy, flagged. The squash copy also stands in
  (flagged) when GitHub can't be asked. One gh call per PR again.
- The bump reads SUBJECTS only (a note line "fix: …" in a docs PR cut a
  patch); `BREAKING CHANGE` still from bodies.
- Parser: loose and numbered lists; `<!--` inside a code span is text; a
  mid-paragraph label counts only capitalised; `**Fixes: x.**`; input
  squeezed with `tr` (a 65 000-space line took minutes in bash's trims);
  letter sets spelled out (bash 3.2 + UTF-8 reads `[A-Z]` by collation).
- Assembly: a next.md that starts with a section has no title; any other
  heading ends the section above it; `#` lines survive into the tag
  (`git tag --cleanup=whitespace` — the default strip deleted them); a
  first word is capitalised only when plainly lower case ("macOS" stays).
- release.sh puts back what it staged when the release commit fails, so the
  rerun the docs promise works.
- A PR whose commit also edited next.md is named (outside #22 does: its
  entry would ship twice).
- Guard rule 7 matches the name GitHub reports (`name:`, else the id),
  reads contexts line by line, and skips an unstaged deletion.
- The ruleset record gains the two fields the live ruleset carries
  (`require_extra_approval_for_unattributed_changes`, `required_reviewers`),
  so a PUT changes only the new check; README: apply after this merges.
- #42's live note has SIX entries (not four).
