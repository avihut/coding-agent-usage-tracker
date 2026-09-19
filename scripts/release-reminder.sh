#!/usr/bin/env bash
# post-merge reminder (daft.yml): a shipped feature or fix is not done until
# it is released, in the same session (CLAUDE.md, release ritual — written
# after a session committed two changes and stopped, and every install
# stayed behind). Exits non-zero while main holds unreleased feat/fix
# commits so daft shows it as a warning row; post-merge never rolls back.
set -euo pipefail

# See digest-baseline.sh: the cwd (the target worktree) is authoritative.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

branch=$(git symbolic-ref --short -q HEAD || true)
if [ "$branch" != "main" ]; then
    echo "release-reminder: '$branch' is not main — releases are cut from main"
    exit 0
fi

last=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
range=${last:+$last..}HEAD
unreleased=$(git log --format='%h %s' "$range" | grep -E '^[0-9a-f]+ (feat|fix)(\([^)]*\))?!?: ' || true)

if [ -z "$unreleased" ]; then
    echo "release-reminder: nothing unreleased on main since ${last:-the first commit}"
    exit 0
fi

cat >&2 <<EOF
main holds unreleased work since ${last:-the first commit}:
$(printf '%s\n' "$unreleased" | sed 's/^/  /')

The release ritual (minor for feat, patch for fix) — same session:
  1. bump AppIdentity.version
  2. commit 'release: vX.Y.Z' (body: what shipped)
  3. git tag -a vX.Y.Z   (the annotation is the release notes)
  4. git push origin main vX.Y.Z
  5. mise run publish
EOF
exit 1
