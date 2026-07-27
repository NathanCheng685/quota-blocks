#!/bin/zsh
set -euo pipefail

# One-time setup: create a STABLE self-signed code-signing identity in the
# login keychain, then rebuild + reinstall Quota Blocks signed with it.
#
# Why: the app was ad-hoc signed (`codesign --sign -`), which has no stable
# signing identity. macOS therefore refuses to durably remember the keychain
# "Always Allow" grant for the Claude credential, so every login re-prompts for
# your password. A stable identity makes that grant persist.
#
# Run this ONCE in your own Terminal (it needs interactive keychain access):
#   ./scripts/setup-signing-identity.sh
# Then launch Quota Blocks and click "Always Allow" on the keychain prompt once.

ROOT="${0:A:h:h}"
cd "$ROOT"

IDENTITY="QuotaBlocks Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
    # OpenSSL 3 <-> macOS `security import` cannot agree on a PKCS#12/PEM private
    # key format, so create the identity with Apple's own Certificate Assistant,
    # which builds the cert + key directly in the keychain with no format issues.
    cat >&2 <<INSTRUCTIONS
✘ Code-signing identity "$IDENTITY" not found.

Create it once with Keychain Access (30 seconds), then re-run this script:

  1. Open Keychain Access (⌘-Space, type "Keychain Access").
  2. Menu bar: Keychain Access ▸ Certificate Assistant ▸ Create a Certificate…
  3. Name:            $IDENTITY
     Identity Type:   Self Signed Root
     Certificate Type: Code Signing
  4. Click Create, accept the warning, Done.
  5. Re-run:  ./scripts/setup-signing-identity.sh

INSTRUCTIONS
    exit 1
fi
echo "✔︎ Code-signing identity '$IDENTITY' found."

echo "→ Rebuilding and reinstalling Quota Blocks signed with '$IDENTITY'…"
QUOTABLOCKS_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/install-local.sh"

echo
echo "✔︎ Done. Quota Blocks is now signed with a stable identity."
echo "  Verify:  codesign -dv --verbose=4 '/Applications/Quota Blocks.app' 2>&1 | grep -i Authority"
echo "  Next:    when Quota Blocks next reads the Claude credential, click"
echo "           \"Always Allow\" on the keychain prompt ONE time. It will stick."
