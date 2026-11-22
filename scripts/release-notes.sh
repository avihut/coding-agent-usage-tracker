#!/usr/bin/env bash
# The release-note grammar, in ONE place: CI's `release-note` check reads a
# pull request's description with it, and release.sh assembles the release
# notes with it — so a description the check passes is one the release can
# read. Release notes used to be appended to .release-notes/next.md on each
# branch, and every PR editing that one file conflicted with every other
# open PR (user-directed 2026-11-22: notes live in the PR description now).
#
#   release-notes.sh check            a PR description on stdin; exit 0 when it
#                                     has a usable "## Release note", else 1 + why
#   release-notes.sh entries          a PR description on stdin → one
#                                     "<fixes|features><TAB><text>" line per entry;
#                                     exit 0, 1 (no section), 2 (nothing usable)
#   release-notes.sh commit-entries   a commit message on stdin → the same lines,
#                                     from "Release note — Fixes: …" paragraphs
#   release-notes.sh assemble <range> <fallback subject>
#                                     .release-notes/next.md + every commit in the
#                                     range → the notes on stdout, warnings on
#                                     stderr; exit 1 when a description cannot be
#                                     read or its note is malformed
#
# THE GRAMMAR. A heading "Release note" (any level, any case, "notes" too),
# up to the next heading. In it: `none`, or entries — each starts on a line
# labelled `Fixes:` / `Fix:` or `New:` / `Features:` / `Feature:` and runs to
# the next blank line; repeat the label for a second entry, or put bullets
# (`- `, `* `, `1. `; tight or loose) under a bare label for one entry per
# bullet. In mid-paragraph a label counts only capitalised, as written. The
# note ends at the first paragraph that carries no label (a signature, a
# link), so nothing after it leaks in. HTML comments (the template's hint)
# are not text, except inside a code span.
#
# assemble: a subject ending in "(#N)" — GitHub's squash convention — is PR
# N, and its note is its description AS IT STOOD AT THE MERGE: the live one
# (GitHub's GraphQL API, through gh), unless it was edited after the merge,
# and then the copy GitHub put in the squash commit's body. That copy also
# stands in when GitHub can't be asked. RELEASE_NOTES_PRS=<file.json>, a JSON
# array of {number, body, lastEditedAt?, mergedAt?}, stands in for gh
# (scripts/test-hooks.sh), and then gh is never called. Any other commit is
# read for its own "Release note — <Label>: …" paragraph.

# Plain bash, deliberately — `read` and `case` globs, which bash implements
# itself — so the check behaves the same on CI's Ubuntu runner (mawk, glibc)
# as on a Mac (BSD awk), and bash 3.2-safe like every hook script. Every value
# is quoted and printed with printf '%s': a description is an outsider's text.
set -euo pipefail
shopt -s nocasematch

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE # see digest-baseline.sh

tab=$'\t'
# Letters spelled out, never as a range: under a UTF-8 locale bash 3.2 reads
# [A-Z] in collation order (aAbB…), so "n" falls inside it.
upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ
lower=abcdefghijklmnopqrstuvwxyz
notes_file=${RELEASE_NOTES_FILE:-.release-notes/next.md}

trim() { # <text> → trimmed of spaces and tabs at both ends, in $trimmed
    trimmed=$1
    while [[ $trimmed == [" $tab"]* ]]; do trimmed=${trimmed:1}; done
    while [[ $trimmed == *[" $tab"] ]]; do trimmed=${trimmed%?}; done
}

# What the readers read: tabs and CRs (a description edited on github.com
# arrives CRLF) become spaces, and every run of spaces one — which this
# grammar never tells apart, and which keeps every trim above O(1): bash
# strips a 65 000-space run one character, or one pattern try, at a time
# (seconds to minutes), and a description is an outsider's text. Bytes, not
# characters (LC_ALL=C): an invalid sequence must not stop tr.
normalized() { LC_ALL=C tr '\t\r' '  ' | LC_ALL=C tr -s ' '; }

# HTML comments, across lines: `strip_comment <line>` leaves the line's text
# outside any comment in $uncommented, and whether the line was nothing BUT
# comment in $comment_only (a dropped line, not a blank one).
in_comment=false
strip_comment() {
    local rest=$1 out="" had=false
    while :; do
        if $in_comment; then
            had=true
            if [[ $rest == *"-->"* ]]; then
                rest=${rest#*"-->"}
                in_comment=false
            else
                rest=""
                break
            fi
        elif [[ $rest == *"<!--"* ]]; then
            local before=${rest%%"<!--"*} ticks
            rest=${rest#*"<!--"}
            # Inside a code span (an odd number of backticks before it on
            # this line), `<!--` is text, as GitHub renders it.
            ticks=$out$before
            ticks=${ticks//[!\`]/}
            if [ $((${#ticks} % 2)) = 1 ]; then
                out+=$before'<!--'
                continue
            fi
            had=true
            out+=$before
            in_comment=true
        else
            out+=$rest
            break
        fi
    done
    uncommented=$out
    trim "$out"
    comment_only=false
    if $had && [ -z "$trimmed" ]; then comment_only=true; fi
}

# A markdown heading: 1–6 `#`, then a space or nothing. "#45 fixed it" is not
# one. Leaves the heading's text, trimmed, in $heading_text.
is_heading() {
    local line=$1 hashes after
    trim "$line"
    line=$trimmed
    hashes=${line:0:7}
    hashes=${hashes%%[!#]*}
    [ -n "$hashes" ] && [ ${#hashes} -le 6 ] || return 1
    after=${line#"$hashes"}
    [[ -z $after || $after == [" $tab"]* ]] || return 1
    trim "$after"
    heading_text=$trimmed
    while [[ $heading_text == *'#' ]]; do heading_text=${heading_text%'#'}; done # closing hashes
    trim "$heading_text"
    heading_text=$trimmed
}

is_release_heading() { # <line>
    is_heading "$1" || return 1
    local text=${heading_text%:}
    [[ $text == "release note" || $text == "release notes" ]]
}

# `split_label <line> [strict]`: a line that opens an entry. Sets $label_key
# (fixes or features) and $label_rest (the text after the label). `strict`,
# for a line in the middle of a paragraph, wants the label capitalised as
# written ("Fixes:"), so prose wrapped onto "new: a dot…" stays prose.
split_label() {
    local s word rest bold=false
    trim "$1"
    s=$trimmed
    case $s in '- '* | '* '*) s=${s:2} ;; esac
    if [[ $s == '**'* ]]; then
        bold=true
        s=${s:2}
    fi
    [[ $s == *:* ]] || return 1
    word=${s%%:*}
    word=${word%'**'}
    case $word in
    fixes | fix) label_key=fixes ;;
    new | features | feature) label_key=features ;;
    *) return 1 ;;
    esac
    if [ "${2:-}" = strict ]; then
        shopt -u nocasematch
        if [[ $word != ["$upper"]* ]]; then
            shopt -s nocasematch
            return 1
        fi
        shopt -s nocasematch
    fi
    rest=${s#*:}
    rest=${rest#'**'}
    trim "$rest"
    label_rest=$trimmed
    if $bold && [[ $label_rest == *'**' ]]; then label_rest=${label_rest%'**'}; fi # **Fixes: x.**
    return 0
}

is_none() { # <paragraph's first line>
    local s
    trim "$1"
    s=$trimmed
    while [[ $s == [_*\`]* ]]; do s=${s:1}; done
    while [[ $s == *[_*\`.] ]]; do s=${s%?}; done
    [[ $s == none ]]
}

is_bullet() { # <line> → its text in $bullet_text: "- x", "* x", "1. x", "2) x"
    trim "$1"
    case $trimmed in
    '- '* | '* '* | [0-9]'. '* | [0-9][0-9]'. '* | [0-9]') '* | [0-9][0-9]') '*)
        bullet_text=${trimmed#*' '}
        return 0
        ;;
    esac
    return 1
}

# One entry being read: emitted when the next one starts or the note ends.
entry_key="" entry_text="" emitted=0
emit() {
    trim "$entry_text"
    if [ -n "$trimmed" ]; then
        printf '%s\t%s\n' "$entry_key" "${trimmed//$tab/ }"
        emitted=$((emitted + 1))
    fi
    entry_text=""
}
append() { # <line> → onto the entry, wrapped lines joined with one space
    trim "$1"
    if [ -z "$entry_text" ]; then entry_text=$trimmed; else entry_text+=" $trimmed"; fi
}

# The PR-description reader. Prints entries; the reason for a non-zero exit
# goes to stderr.
read_description() {
    local line found=false in_fence=false state=leading blank_before=false bare_label=false first_text="" strict
    in_comment=false entry_text="" emitted=0
    while IFS= read -r line || [ -n "$line" ]; do
        strip_comment "$line"
        $comment_only && continue
        line=$uncommented
        trim "$line"
        if [[ $trimmed == '```'* || $trimmed == '~~~'* ]]; then
            if $in_fence; then in_fence=false; else in_fence=true; fi
        fi
        if ! $in_fence && is_heading "$line"; then
            if $found; then break; fi
            if is_release_heading "$line"; then found=true; fi
            continue
        fi
        $found || continue
        case $state in none | ended) continue ;; esac

        trim "$line"
        if [ -z "$trimmed" ]; then
            blank_before=true
            continue
        fi
        strict=strict # in mid-paragraph a label must be written as one
        if [ "$state" = leading ] || $blank_before; then strict=""; fi
        if split_label "$line" "$strict"; then
            [ "$state" = entry ] && emit
            state=entry entry_key=$label_key entry_text="" blank_before=false
            bare_label=true
            if [ -n "$label_rest" ]; then
                bare_label=false
                append "$label_rest"
            fi
            continue
        fi
        case $state in
        leading)
            if is_none "$line"; then
                state=none
            else
                first_text=$trimmed
                state=ended
            fi
            ;;
        entry)
            if $bare_label && is_bullet "$line"; then
                emit # a bare label's bullets, loose (blank lines between) or tight
                append "$bullet_text"
            elif $blank_before && ! { $bare_label && [ -z "$entry_text" ]; }; then
                emit
                state=ended # the note ended at the last blank line
            else
                append "$line"
            fi
            blank_before=false
            ;;
        esac
    done < <(normalized)
    [ "$state" = entry ] && emit

    if ! $found; then
        echo "no \"## Release note\" section" >&2
        return 1
    fi
    if [ "$state" = none ] || [ "$emitted" -gt 0 ]; then
        return 0
    fi
    if [ -n "$first_text" ]; then
        printf 'the "## Release note" section has no label: "%.70s"\n' "$first_text" >&2
    else
        echo 'the "## Release note" section is empty' >&2
    fi
    return 2
}

# The commit-message reader: "Release note — Fixes: …" (or –, --, -, :) opens
# an entry that runs to the next blank line. "Release note: a Fixes entry in
# next.md" is prose about a note, not one — after the separator comes a word
# that is not a label.
read_commit() {
    local line rest reading=false
    entry_text="" emitted=0
    while IFS= read -r line || [ -n "$line" ]; do
        trim "$line"
        if [ -z "$trimmed" ]; then
            $reading && emit
            reading=false
            continue
        fi
        if [[ $trimmed == "release notes"* ]]; then
            rest=${trimmed:13}
        elif [[ $trimmed == "release note"* ]]; then
            rest=${trimmed:12}
        else
            rest=""
        fi
        if [ -n "$rest" ]; then
            trim "$rest"
            rest=$trimmed
            case $rest in
            '—'*) rest=${rest#'—'} ;;
            '–'*) rest=${rest#'–'} ;;
            '--'*) rest=${rest#'--'} ;;
            '-'*) rest=${rest#'-'} ;;
            ':'*) rest=${rest#':'} ;;
            *) rest="" ;;
            esac
        fi
        if [ -n "$rest" ] && split_label "$rest"; then
            $reading && emit
            reading=true entry_key=$label_key entry_text=""
            append "$label_rest"
        elif $reading; then
            append "$line"
        fi
    done < <(normalized)
    if $reading; then emit; fi
    return 0
}

# ── assemble ────────────────────────────────────────────────────────────────

warn() { printf 'release: %s\n' "$1" >&2; }
problems=0
problem() {
    problems=$((problems + 1))
    printf 'release: ✗ %s\n' "$1" >&2
}

releasable() { # <subject> — feat or fix, the subjects that cut a release
    [[ $1 == feat[:\(!]* || $1 == fix[:\(!]* ]]
}

# PR N's description as it reads NOW, into $body, with when it was last
# edited ($edited_at, empty if never) and merged ($merged_at), from GitHub's
# GraphQL API (`gh pr view` has no edit time). Returns 0 (read), 3 (no such
# pull request — an issue's number, say), 1 (could not ask: $gh_error).
pr_live() {
    local number=$1 out err head
    body="" edited_at="" merged_at="" gh_error=""
    if [ -n "${RELEASE_NOTES_PRS:-}" ]; then
        if ! jq -e --argjson n "$number" 'any(.[]; .number == $n)' "$RELEASE_NOTES_PRS" >/dev/null; then
            return 3
        fi
        out=$(jq -r --argjson n "$number" 'first(.[] | select(.number == $n)) |
            "\(.lastEditedAt // "")\t\(.mergedAt // "")\n\(.body // "")"' "$RELEASE_NOTES_PRS")
    else
        if ! command -v gh >/dev/null 2>&1; then
            gh_error="gh is not installed (brew install gh; gh auth login)"
            return 1
        fi
        err=$(mktemp)
        # shellcheck disable=SC2016 # $owner/$name/$n are GraphQL variables
        if ! out=$(gh api graphql -F owner='{owner}' -F name='{repo}' -F n="$number" \
            -f query='query($owner: String!, $name: String!, $n: Int!) {
                repository(owner: $owner, name: $name) {
                    pullRequest(number: $n) { lastEditedAt mergedAt body } } }' \
            --jq '.data.repository.pullRequest |
                "\(.lastEditedAt // "")\t\(.mergedAt // "")\n\(.body // "")"' 2>"$err"); then
            gh_error=$(grep -v -e '^hint:' -e '^  ' "$err" | head -n 3 | tr '\n' ' ' || true)
            rm -f "$err"
            if [[ $gh_error == *"Could not resolve to a PullRequest"* ]]; then return 3; fi
            return 1
        fi
        rm -f "$err"
    fi
    head=${out%%$'\n'*}
    edited_at=${head%%"$tab"*}
    merged_at=${head#*"$tab"}
    if [[ $out == *$'\n'* ]]; then body=${out#*$'\n'}; fi
    return 0
}

# GitHub's stamps are ISO 8601 in UTC, to the second ("2026-11-21T23:28:14Z"):
# as digits alone they compare as numbers — no locale collation involved.
edited_after_merge() {
    local edited=${edited_at//[!0-9]/} merged=${merged_at//[!0-9]/}
    [ -n "$edited" ] && [ -n "$merged" ] && [ "$edited" -gt "$merged" ]
}

# Word-wrapped at 76 columns as next.md's bullets are: "- " and a two-space
# hanging indent; a first word in plain lower case capitalised ("Fixes: the
# daemon…" → "- The daemon…") — never a name ("macOS", "usage-cli",
# "`--digest`"); every word otherwise verbatim.
bullet() { # <text>
    local text=$1 first words word out="" line="- " width=76
    first=${text%% *}
    first=${first%[,.;:]}
    shopt -u nocasematch
    if [[ -n $first && $first != *[!"$lower"]* ]]; then
        text=$(printf '%s' "${text:0:1}" | LC_ALL=C tr '[:lower:]' '[:upper:]')${text:1}
    fi
    shopt -s nocasematch
    read -r -a words <<<"$text"
    for word in ${words[@]+"${words[@]}"}; do
        if [ "$line" != "- " ] && [ "$line" != "  " ] && [ $((${#line} + 1 + ${#word})) -gt "$width" ]; then
            out+=$line$'\n'
            line="  $word"
        elif [ "$line" = "- " ] || [ "$line" = "  " ]; then
            line+=$word
        else
            line+=" $word"
        fi
    done
    printf '%s%s\n' "$out" "$line"
}

# The heading a line names, if it is one of next.md's section headings:
# "Fixes" / "New" / "Features", alone on the line, `#`s or a colon allowed.
section_key() { # <line> → $section in fixes|features, or 1
    local text
    if is_heading "$1"; then text=$heading_text; else
        trim "$1"
        text=$trimmed
    fi
    text=${text%:}
    case $text in
    fixes | fix) section=fixes ;;
    new | features | feature) section=features ;;
    *) return 1 ;;
    esac
}

assemble() {
    local range=$1 fallback=$2 sha subject number short status entries one why frozen before
    local frozen_status live_status source
    if [ -n "${RELEASE_NOTES_PRS:-}" ] && ! jq -e 'type == "array"' "$RELEASE_NOTES_PRS" >/dev/null 2>&1; then
        problem "RELEASE_NOTES_PRS=$RELEASE_NOTES_PRS is not a JSON array of {number, body, lastEditedAt?, mergedAt?}"
        return 1
    fi
    entries=$(mktemp)
    one=$(mktemp)
    why=$(mktemp)
    frozen=$(mktemp)

    while IFS="$tab" read -r sha subject; do
        [ -n "$sha" ] || continue
        short=${sha:0:7}
        number=""
        if [[ $subject == *'(#'*')' ]]; then
            number=${subject##*'(#'}
            number=${number%')'}
            [[ -n $number && $number != *[!0-9]* ]] || number=""
        fi
        if [ -n "$number" ]; then
            # THE NOTE IS THE DESCRIPTION AS IT STOOD AT THE MERGE — the text
            # CI's check passed and the merger saw. That is the live one,
            # unless it was edited after the merge (an author can; read live,
            # that edit would reach the tag unreviewed). The squash commit's
            # body is a copy, but from when the squash message was FIXED: on
            # an auto-merge that is when it was armed, so it can predate the
            # last edit (#42's is two revisions old). It is the fallback.
            frozen_status=0
            read_description <<<"$(git log -1 --format=%B "$sha")" >"$frozen" 2>/dev/null || frozen_status=$?
            live_status=0
            pr_live "$number" || live_status=$?
            source=live
            case $live_status in
            0) if edited_after_merge; then
                if [ "$frozen_status" = 0 ]; then
                    source=frozen
                    warn "#$number's description was edited AFTER its merge ($edited_at) — using the copy in its squash commit instead; review it against the PR"
                else
                    warn "#$number's description was edited AFTER its merge ($edited_at) and its squash commit carries no note — using the edited description; review it before pushing"
                fi
            fi ;;
            1) if [ "$frozen_status" = 0 ]; then
                source=frozen
                warn "#$number: its description could not be read ($gh_error) — using the copy in its squash commit, which may predate its last edit; review it"
            elif releasable "$subject"; then
                problem "#$number ($subject): its description could not be read — $gh_error"
                continue
            else
                # Only a feat or fix cuts a release, so only theirs is worth
                # refusing one over: Dependabot's chores, offline, never are.
                warn "#$number ($subject): its description could not be read — nothing from it ($gh_error)"
                continue
            fi ;;
            3) if [ "$frozen_status" = 0 ]; then
                source=frozen
            else
                warn "$short ends in (#$number), which is not a pull request here — reading its commit message instead"
                source=commit
            fi ;;
            esac
            if [ "$source" = live ]; then
                status=0
                read_description <<<"$body" >"$one" 2>"$why" || status=$?
                case $status in
                0) if [ "$frozen_status" = 0 ] && ! cmp -s "$one" "$frozen"; then
                    warn "#$number: its squash commit holds an older note (the merge message was fixed before the last edit) — using the description as merged"
                fi ;;
                1) if releasable "$subject"; then warn "#$number has no \"## Release note\" — nothing from it ($subject)"; fi ;;
                2) problem "#$number: $(cat "$why") — fix its description (gh pr edit $number), then: mise run release" ;;
                esac
            elif [ "$source" = frozen ]; then
                cp "$frozen" "$one"
            fi
            if [ "$source" != commit ]; then
                if [ -s "$one" ] && [ -n "$(git diff-tree --no-commit-id --name-only -r "$sha" -- "$notes_file")" ]; then
                    warn "#$number also edited $notes_file — its entry may now be there twice; check the notes"
                fi
                cat "$one" >>"$entries"
                continue
            fi
        fi
        before=$(wc -l <"$entries")
        git log -1 --format=%B "$sha" | read_commit >>"$entries"
        if [ -z "$number" ] && [ "$(wc -l <"$entries")" = "$before" ] && releasable "$subject"; then
            warn "$short has no PR and no \"Release note — …\" paragraph — nothing from it ($subject)"
        fi
    done < <(git log --reverse --format="%H$tab%s" "$range")

    merge_notes "$fallback" <"$entries"
    rm -f "$entries" "$one" "$why" "$frozen"
    [ "$problems" -eq 0 ]
}

# next.md (its comment stripped) with the collected entries merged in: each
# appended to the END of its section (the maintainer's entries first, then
# the PRs' in merge order); a section next.md lacks follows the others,
# Fixes then Features, as next.md has had them.
merge_notes() { # <fallback subject>; entries on stdin
    local fallback=$1 key text line subject="" started=false i n=0 block
    local fixes="" features="" fixes_used=false features_used=false
    while IFS="$tab" read -r key text; do
        case $key in
        fixes) fixes+=$(bullet "$text")$'\n' ;;
        features) features+=$(bullet "$text")$'\n' ;;
        esac
    done

    # Blocks: 0 is the prose before any heading, then one per section.
    local -a keys=("") texts=("")
    if [ -f "$notes_file" ]; then
        in_comment=false
        while IFS= read -r line || [ -n "$line" ]; do
            strip_comment "$line"
            $comment_only && continue
            line=$uncommented
            if ! $started; then
                trim "$line"
                [ -z "$trimmed" ] && continue
                started=true
                # The first line is the title — unless next.md starts with a
                # section, and then it has none. (section_key trims too: keep
                # the line before it runs.)
                local first=$trimmed
                if ! section_key "$line"; then
                    subject=$first
                    continue
                fi
            fi
            if section_key "$line"; then
                n=$((n + 1))
                keys[n]=$section
                texts[n]=$line$'\n'
            elif is_heading "$line"; then
                # Any other heading ("## Upgrading") ends the section above
                # it, so its entries go before it, not after its text.
                n=$((n + 1))
                keys[n]=""
                texts[n]=$line$'\n'
            else
                texts[n]+=$line$'\n'
            fi
        done <"$notes_file"
    fi

    if [ -z "$subject" ] && [ -z "$fixes$features" ]; then
        return 0 # nothing written, nothing collected: release.sh lists subjects
    fi
    if [ -z "$subject" ]; then
        subject=$fallback
        warn "next.md has no title — the tag's subject is '$fallback'"
    fi

    printf '%s\n' "$subject"
    for i in $(seq 0 "$n"); do
        block=${texts[i]}
        case ${keys[i]} in
        fixes) if ! $fixes_used; then
            block=$(trim_blank "$block")$'\n'$fixes
            fixes_used=true
        fi ;;
        features) if ! $features_used; then
            block=$(trim_blank "$block")$'\n'$features
            features_used=true
        fi ;;
        esac
        block=$(trim_blank "$block")
        [ -n "$block" ] && printf '\n%s\n' "$block"
    done
    if ! $fixes_used && [ -n "$fixes" ]; then printf '\nFixes\n%s' "$fixes"; fi
    if ! $features_used && [ -n "$features" ]; then printf '\nFeatures\n%s' "$features"; fi
    return 0
}

trim_blank() { # <text> → without blank lines at either end
    local s=$1
    while [[ $s == $'\n'* ]]; do s=${s#$'\n'}; done
    while [[ $s == *$'\n' ]]; do s=${s%$'\n'}; done
    printf '%s' "$s"
}

case ${1:-} in
check)
    description=$(cat)
    status=0
    entries=$(read_description <<<"$description" 2>/dev/null) || status=$?
    if [ "$status" = 0 ]; then
        if [ -z "$entries" ]; then
            echo "release note: none — this change adds nothing to the release notes"
        else
            printf 'release note: %s entr%s\n' "$(printf '%s\n' "$entries" | wc -l | tr -d ' ')" \
                "$([ "$(printf '%s\n' "$entries" | wc -l | tr -d ' ')" = 1 ] && echo y || echo ies)"
            printf '%s\n' "$entries" | sed "s/$tab/: /"
        fi
        exit 0
    fi
    printf 'release note: %s\n' "$(read_description <<<"$description" 2>&1 >/dev/null || true)" >&2
    cat >&2 <<'EOF'
The pull request's description needs a "## Release note" section: what a
user will notice, one paragraph starting with Fixes:, New: or Features:
(repeat the label for a second entry) — or the word none. scripts/release.sh
collects it into the release notes (docs/WORKFLOW.md, the release ritual).
Editing the description re-runs this check; "Re-run jobs" re-reads the old one.
EOF
    exit 1
    ;;
entries) read_description ;;
commit-entries) read_commit ;;
assemble)
    [ $# -eq 3 ] || {
        echo "usage: release-notes.sh assemble <range> <fallback subject>" >&2
        exit 64
    }
    assemble "$2" "$3"
    ;;
*)
    echo "usage: release-notes.sh check|entries|commit-entries|assemble <range> <subject>" >&2
    exit 64
    ;;
esac
