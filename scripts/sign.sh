#!/bin/zsh
# Signs a binary with a stable, machine-local identity. SPM ad-hoc signs by
# default, and an ad-hoc identity changes with every build — a real
# certificate keeps the app's identity constant across rebuilds (launchd job,
# updater's codesign verification, Gatekeeper's memory of the bundle).
#
# No identity is hardcoded here: whoever clones the repo signs with their own.
# Resolution order:
#   1. $CODESIGN_IDENTITY — explicit. Put it in mise.local.toml (git-ignored;
#      see mise.local.toml.example) to pin one identity for this checkout.
#   2. Auto-discovery — the first codesigning identity in the login keychain,
#      preferring "Developer ID Application" > "Apple Development" >
#      "Mac Developer" (a free Apple ID in Xcode yields the second kind).
#   3. Ad-hoc ("-"), with a warning. Fine for a local dev build; refused when
#      CODESIGN_REQUIRE_IDENTITY=1 (dist.sh sets it — never ship ad-hoc).
#
#   scripts/sign.sh --which        print the resolved identity and how it was found
#                                  (exit 1 if ad-hoc and CODESIGN_REQUIRE_IDENTITY is set)
#   scripts/sign.sh <binary>       sign (CODESIGN_TIMESTAMP=1 adds a secure timestamp)
set -euo pipefail

resolve_identity() {
    if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
        RESOLVED="$CODESIGN_IDENTITY"
        SOURCE='$CODESIGN_IDENTITY'
        return
    fi
    local list kind match
    list=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -nE 's/^ *[0-9]+\) [0-9A-F]+ "(.*)"$/\1/p') || true
    for kind in "Developer ID Application" "Apple Development" "Mac Developer"; do
        match=$(printf '%s\n' "$list" | grep -F -m1 "$kind: ") || true
        if [[ -n "$match" ]]; then
            RESOLVED="$match"
            SOURCE="login keychain (security find-identity)"
            return
        fi
    done
    RESOLVED="-"
    SOURCE="none found — ad-hoc"
}

RESOLVED=""
SOURCE=""
resolve_identity

if [[ "${1:-}" == "--which" ]]; then
    echo "identity: $RESOLVED"
    echo "source:   $SOURCE"
    if [[ "$RESOLVED" == "-" ]]; then
        echo "hint:     Xcode → Settings → Accounts → Manage Certificates → + Apple Development,"
        echo "          or set CODESIGN_IDENTITY (mise.local.toml). See README → Code signing."
        # Lets dist.sh fail fast, before its universal builds, not after.
        [[ -n "${CODESIGN_REQUIRE_IDENTITY:-}" ]] && exit 1
    fi
    exit 0
fi

BINARY="${1:?usage: sign.sh <path-to-binary> | --which}"

if [[ "$RESOLVED" == "-" ]]; then
    if [[ -n "${CODESIGN_REQUIRE_IDENTITY:-}" ]]; then
        echo "sign.sh: no code-signing identity found and this build refuses ad-hoc." >&2
        echo "         Add an Apple Development certificate in Xcode (Settings → Accounts →" >&2
        echo "         Manage Certificates) or set CODESIGN_IDENTITY. README → Code signing." >&2
        exit 1
    fi
    echo "sign.sh: no code-signing identity found — ad-hoc signing $(basename "$BINARY")." >&2
    echo "         Fine for a local build; run 'mise run identity' for a stable one." >&2
fi

# A secure timestamp keeps the signature valid after the certificate expires
# (they last a year). Opt-in: the dev loop re-signs constantly and shouldn't
# need Apple's timestamp server to be reachable. It leaves the designated
# requirement untouched. Ad-hoc signatures cannot carry one.
if [[ -n "${CODESIGN_TIMESTAMP:-}" && "$RESOLVED" != "-" ]]; then
    codesign --force --timestamp --sign "$RESOLVED" "$BINARY"
else
    codesign --force --sign "$RESOLVED" "$BINARY"
fi
codesign --display --verbose=2 "$BINARY" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)' || true
