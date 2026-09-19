#!/usr/bin/env bash
# pre-merge ring (daft.yml): every commit the merge would land has a
# conventional subject. The commit-msg hook already checks each message as
# it is written — this catches the ones written with --no-verify, or in a
# clone that never installed the hooks.
set -euo pipefail

# See digest-baseline.sh: the cwd (the source worktree) is authoritative.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# No apostrophe in the message: inside ${VAR:?…} bash 3.2 reads one as an
# unterminated quote.
target="${DAFT_MERGE_TARGET_BRANCH:?run this from the daft pre-merge hook, or set DAFT_MERGE_TARGET_BRANCH}"
exec cog check --ignore-merge-commits --ignore-fixup-commits "refs/heads/$target..HEAD"
