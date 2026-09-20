#!/usr/bin/env bash
# Repo-rule tripwires: the hard rules of CLAUDE.md / docs/SPEC.md §10 that a
# grep can hold. Each is a tripwire, not a proof — it catches the careless
# regression, and its failure message names the rule so a deliberate change
# is made as one (amend the rule, then the list below, in the same commit).
#
#   scripts/guard.sh            the working tree (tracked files)
#   scripts/guard.sh --staged   the index — what a commit is about to record
#
# bash, not the zsh of the scripts around it, so shellcheck can hold it.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

grep_tree=(git grep -I)
show() { cat -- "$1"; }
if [ "${1:-}" = "--staged" ]; then
    grep_tree=(git grep -I --cached)
    show() { git show ":$1"; }
fi

failures=0
fail() {
    failures=$((failures + 1))
    printf '\n✗ %s\n' "$1" >&2
    shift
    printf '  %s\n' "$@" >&2
}

# 1. The token is never persisted (§10). Fixtures carry percentages and dates,
#    never a credential — an OAuth token has this shape wherever it appears.
if hits=$("${grep_tree[@]}" -nE 'sk-ant-[a-z0-9]+-[A-Za-z0-9_-]{8,}'); then
    fail "a token-shaped string is tracked (spec §10: the token is never persisted)" \
        "$(cut -d: -f1,2 <<<"$hits")"
fi

# 2. No developer account is named anywhere in the repo (sign.sh resolves a
#    machine-local identity). A real identity ends in its 10-character team
#    ID; the example file's "(TEAMID)" placeholder does not.
identity='(Developer ID Application|Apple Development|Apple Distribution|Mac Developer): [^"()]*\([A-Z0-9]{10}\)'
if hits=$("${grep_tree[@]}" -nE "$identity"); then
    fail "a code-signing identity is hardcoded (docs/WORKFLOW.md: machine-local identity only)" \
        "$(cut -d: -f1,2 <<<"$hits")"
fi

# 3. Zero third-party Swift dependencies; the TUI carries exactly four crates.
if show Package.swift | grep -nE '\.package\(' >/dev/null; then
    fail "Package.swift declares a package dependency (CLAUDE.md: Foundation/AppKit/SwiftUI only)"
fi
allowed_crates="ratatui serde serde_json time"
crates=$(show tui/Cargo.toml |
    awk '/^\[/ { on = ($0 ~ /^\[(dev-|build-)?dependencies\]/) ; next } on && /^[A-Za-z0-9_-]+ *=/ { print $1 }')
for crate in $crates; do
    case " $allowed_crates " in
    *" $crate "*) ;;
    *) fail "tui/Cargo.toml depends on '$crate' (CLAUDE.md: exactly $allowed_crates)" ;;
    esac
done

# 4. Every host the shipped code names. The first four are the network
#    destinations §10 allows; the rest are links the user's browser opens.
#    A new host here is a §10 question before it is a code change.
allowed_hosts="
api.anthropic.com
raw.githubusercontent.com
status.claude.com
api.github.com
github.com
stspg.io
claude.ai
openai.com
one.google.com
"
hosts=$("${grep_tree[@]}" -hoE 'https?://[A-Za-z0-9.-]+' -- Sources tui/src |
    sed -E 's#^https?://##' | sort -u || true)
for host in $hosts; do
    if ! grep -qxF "$host" <<<"$allowed_hosts"; then
        where=$("${grep_tree[@]}" -nF "://$host" -- Sources tui/src | cut -d: -f1,2 | head -3)
        fail "'$host' is not a host this app is allowed to name (spec §10: network destinations)" \
            "$where" \
            "amend §10 first, then add the host to scripts/guard.sh"
    fi
done

# 5. Every dev-lifecycle script is runnable as a mise task. `ls-files` reads
#    the index, so a script staged for its first commit is already counted.
while IFS= read -r script; do
    if ! show mise.toml | grep -qF "$script"; then
        fail "$script has no mise task (CLAUDE.md: a script and its task land together)"
    fi
done < <(git ls-files -- 'scripts/*')

# 6. `ci-gate` is the ONE status check the ruleset requires, and it knows
#    only the jobs its `needs:` lists: a job missing from that list can fail
#    on a pull request that still merges. The same hole one level down — a
#    half of `mise run gate` that no CI job runs.
ci=.github/workflows/ci.yml
if ci_text=$(show "$ci" 2>/dev/null); then
    ci_jobs=$(awk '/^jobs:/ { j = 1; next }
        j && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { sub(/:.*/, ""); sub(/^  /, ""); print }' <<<"$ci_text")
    ci_needs=$(awk '/^  ci-gate:/ { g = 1; next }
        g && /^  [A-Za-z0-9_-]+:/ { g = 0 }
        g && /^    needs:/ { n = 1; next }
        g && n && /^      - / { sub(/^      - /, ""); print; next }
        g && n { n = 0 }' <<<"$ci_text")
    for job in $ci_jobs; do
        [ "$job" = ci-gate ] && continue
        if ! grep -qxF "$job" <<<"$ci_needs"; then
            fail "$ci: job '$job' is not in ci-gate's needs" \
                "ci-gate is the only required check; a job it does not need cannot block a merge"
        fi
    done
    gate_halves=$(show mise.toml | awk '/^\[tasks\.gate\]$/ { g = 1; next } /^\[/ { g = 0 } g && /^depends/' |
        grep -oE '"[^"]+"' | tr -d '"' || true)
    for half in $gate_halves; do
        if ! grep -E '^[[:space:]]*run: mise run ' <<<"$ci_text" | grep -qE "[[:space:]]$half\$"; then
            fail "$ci: no job runs 'mise run $half'" \
                "every half of the gate task runs in CI, or a pull request is held to less than a local merge"
        fi
    done
fi

if [ "$failures" -gt 0 ]; then
    printf '\nguard: %d rule(s) tripped\n' "$failures" >&2
    exit 1
fi
echo "guard: repo rules hold"
