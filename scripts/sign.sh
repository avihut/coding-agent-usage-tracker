#!/bin/zsh
# Signs a binary with a stable identity so the Keychain ACL from "Always Allow"
# survives rebuilds. SPM ad-hoc signs by default, and ad-hoc identity changes
# with every build — which would re-prompt on every rebuild.
set -euo pipefail

IDENTITY="${CODESIGN_IDENTITY:-Apple Development: Avihu Turzion (SHQWV6SKD5)}"
BINARY="${1:?usage: sign.sh <path-to-binary>}"

# A secure timestamp keeps the signature valid after the certificate expires
# (they last a year). Opt-in: the dev loop re-signs constantly and shouldn't
# need Apple's timestamp server to be reachable. It leaves the designated
# requirement — and so the Keychain ACL — untouched.
if [[ -n "${CODESIGN_TIMESTAMP:-}" ]]; then
    codesign --force --timestamp --sign "$IDENTITY" "$BINARY"
else
    codesign --force --sign "$IDENTITY" "$BINARY"
fi
codesign --display --verbose=2 "$BINARY" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)' || true
