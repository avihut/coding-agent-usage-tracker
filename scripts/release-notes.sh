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
# the next blank line; repeat the label for a second entry, or put `- `
# bullets under a bare label for one entry per bullet. The note ends at the
# first paragraph that carries no label (a signature, a link), so nothing
# after it leaks in. HTML comments (the template's hint) are not text.
#
# assemble: a subject ending in "(#N)" — GitHub's squash convention — is PR
# N. Its note is read from the squash commit's own body, which GitHub fills
# with the PR's description: the text as merged, frozen in git, offline.
# Only when that body has no usable note is the description read live with
# `gh pr view` (and the entries flagged for review). RELEASE_NOTES_PRS=
# <file.json>, a JSON array of {number, body} as `gh … --json number,body`
# prints it, stands in for gh (scripts/test-hooks.sh), and then gh is never
# called. Any other commit is read for its own "Release note — <Label>: …"
# paragraph.
#
# Plain bash, deliberately — `read` and `case` globs, which bash implements
# itself — so the check behaves the same on CI's Ubuntu runner (mawk, glibc)
# as on a Mac (BSD awk), and bash 3.2-safe like every hook script. Every value
# is quoted and printed with printf '%s': a description is an outsider's text.
set -euo pipefail
shopt -s nocasematch

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE # see digest-baseline.sh

tab=$'\t'
notes_file=${RELEASE_NOTES_FILE:-.release-notes/next.md}

trim() { # <text> → trimmed of spaces and tabs at both ends, in $trimmed
    trimmed=$1
    while [[ $trimmed == [" $tab"]* ]]; do trimmed=${trimmed:1}; done
    while [[ $trimmed == *[" $tab"] ]]; do trimmed=${trimmed%?}; done
}

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
            had=true
            out+=${rest%%"<!--"*}
            rest=${rest#*"<!--"}
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
    hashes=${line%%[!#]*}
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

# `split_label <line>`: a line that opens an entry. Sets $label_key (fixes or
# features) and $label_rest (the text after the label).
split_label() {
    local s word rest
    trim "$1"
    s=$trimmed
    case $s in '- '* | '* '*) s=${s:2} ;; esac
    s=${s#'**'}
    [[ $s == *:* ]] || return 1
    word=${s%%:*}
    word=${word%'**'}
    case $word in
    fixes | fix) label_key=fixes ;;
    new | features | feature) label_key=features ;;
    *) return 1 ;;
    esac
    rest=${s#*:}
    rest=${rest#'**'}
    trim "$rest"
    label_rest=$trimmed
}

is_none() { # <paragraph's first line>
    local s
    trim "$1"
    s=$trimmed
    while [[ $s == [_*\`]* ]]; do s=${s:1}; done
    while [[ $s == *[_*\`.] ]]; do s=${s%?}; done
    [[ $s == none ]]
}

is_bullet() { # <line> → its text in $bullet_text
    trim "$1"
    case $trimmed in
    '- '* | '* '*)
        bullet_text=${trimmed:2}
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
    local line found=false in_fence=false state=leading blank_before=false bare_label=false first_text=""
    in_comment=false entry_text="" emitted=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'} # a description edited on github.com arrives CRLF
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
        if split_label "$line"; then
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
            if $blank_before && ! { $bare_label && [ -z "$entry_text" ]; }; then
                emit
                state=ended # the note ended at the last blank line
            elif $bare_label && is_bullet "$line"; then
                emit
                append "$bullet_text"
            else
                append "$line"
            fi
            blank_before=false
            ;;
        esac
    done
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
        line=${line%$'\r'}
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
    done
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

# PR N's description into $body. Returns 0 (read), 3 (no such pull request —
# an issue's number, say), 1 (could not ask).
pr_body() {
    local number=$1 err
    body=""
    if [ -n "${RELEASE_NOTES_PRS:-}" ]; then
        if ! jq -e --argjson n "$number" 'any(.[]; .number == $n)' "$RELEASE_NOTES_PRS" >/dev/null; then
            return 3
        fi
        body=$(jq -r --argjson n "$number" 'first(.[] | select(.number == $n)) | .body // ""' "$RELEASE_NOTES_PRS")
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1; then
        gh_error="gh is not installed — it reads the PR descriptions (brew install gh; gh auth login)"
        return 1
    fi
    err=$(mktemp)
    if body=$(gh pr view "$number" --json body --jq .body 2>"$err"); then
        rm -f "$err"
        return 0
    fi
    gh_error=$(grep -v -e '^hint:' -e '^  ' "$err" | head -n 3 | tr '\n' ' ' || true)
    rm -f "$err"
    if [[ $gh_error == *"Could not resolve to a PullRequest"* ]]; then return 3; fi
    return 1
}

# Word-wrapped at 76 columns as next.md's bullets are: "- " and a two-space
# hanging indent; the first letter capitalised ("Fixes: the daemon…" →
# "- The daemon…"); every word otherwise verbatim.
bullet() { # <text>
    local text=$1 first words word out="" line="- " width=76
    first=${text:0:1}
    case $first in [a-z]) text=$(printf '%s' "$first" | tr '[:lower:]' '[:upper:]')${text:1} ;; esac
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
    local range=$1 fallback=$2 sha subject number short status entries one why before
    entries=$(mktemp)
    one=$(mktemp)
    why=$(mktemp)
    if [ -n "${RELEASE_NOTES_PRS:-}" ] && ! jq -e 'type == "array"' "$RELEASE_NOTES_PRS" >/dev/null 2>&1; then
        problem "RELEASE_NOTES_PRS=$RELEASE_NOTES_PRS is not a JSON array of {number, body}"
        return 1
    fi

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
            # FROZEN AT MERGE: GitHub's squash commit carries the PR's
            # description as its body, so the note is read from git — the text
            # that was reviewed and merged, offline. A description stays
            # editable after its merge; read live, an author's later edit
            # would reach the tag unreviewed.
            status=0
            read_description <<<"$(git log -1 --format=%B "$sha")" >"$one" 2>/dev/null || status=$?
            if [ "$status" = 0 ]; then
                cat "$one" >>"$entries"
                continue
            fi
            # No usable note in the commit (a hand-written merge message, a
            # local merge): the live description, flagged for review.
            status=0
            pr_body "$number" || status=$?
            if [ "$status" = 1 ]; then
                problem "#$number ($subject): its squash commit carries no usable \"## Release note\" and its description could not be read — ${gh_error:-gh failed}"
                continue
            fi
            if [ "$status" = 0 ]; then
                status=0
                read_description <<<"$body" >"$one" 2>"$why" || status=$?
                case $status in
                0) if [ -s "$one" ]; then
                    cat "$one" >>"$entries"
                    warn "#$number: read LIVE from its description (its squash commit carries no note) — review these entries before pushing"
                fi ;;
                1) if releasable "$subject"; then warn "#$number has no \"## Release note\" — nothing from it ($subject)"; fi ;;
                2) problem "#$number: $(cat "$why") — fix its description (gh pr edit $number), then: mise run release" ;;
                esac
                continue
            fi
            warn "$short ends in (#$number), which is not a pull request here — reading its commit message instead"
        fi
        before=$(wc -l <"$entries")
        git log -1 --format=%B "$sha" | read_commit >>"$entries"
        if [ -z "$number" ] && [ "$(wc -l <"$entries")" = "$before" ] && releasable "$subject"; then
            warn "$short has no PR and no \"Release note — …\" paragraph — nothing from it ($subject)"
        fi
    done < <(git log --reverse --format="%H$tab%s" "$range")

    merge_notes "$fallback" <"$entries"
    rm -f "$entries" "$one" "$why"
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
                subject=$trimmed
                started=true
                continue
            fi
            if section_key "$line"; then
                n=$((n + 1))
                keys[n]=$section
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
