#!/usr/bin/env bash
# Lints each shell script with the strongest check its shell has. The
# app-lifecycle scripts are zsh, which shellcheck cannot read at all
# (SC1071), so they get zsh's own parser (`zsh -n`: syntax, nothing run);
# the hook scripts are bash precisely so shellcheck can hold them.
#
#   scripts/lint-shell.sh [files…]     default: every tracked scripts/*.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    while IFS= read -r file; do
        files+=("$file")
    done < <(git ls-files -- 'scripts/*.sh')
fi

status=0
for file in ${files[@]+"${files[@]}"}; do
    [ -f "$file" ] || continue # staged as a deletion
    case "$(head -n 1 "$file")" in
    *zsh*) zsh -n "$file" || status=1 ;;
    *) shellcheck "$file" || status=1 ;;
    esac
done
exit "$status"
