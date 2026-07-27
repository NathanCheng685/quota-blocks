#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/Quota Blocks.app"
CONTENTS="$APP/Contents"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/QuotaBlocks" "$CONTENTS/MacOS/QuotaBlocks"
cp "$ROOT/AppBundle/Info.plist" "$CONTENTS/Info.plist"

RESOURCE_BUNDLE="$(find "$BIN_DIR" -maxdepth 1 -type d -name '*QuotaBlocks*.bundle' | head -n 1)"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
fi

# Prefer a stable code-signing identity so the keychain "Always Allow" grant
# for the Claude credential persists across launches. Falls back to ad-hoc
# (the previous behaviour) when the identity is absent, so CI/other machines
# still build. Create the identity once with scripts/setup-signing-identity.sh.
SIGN_IDENTITY="${QUOTABLOCKS_SIGN_IDENTITY:-QuotaBlocks Local Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "Signing with stable identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
    echo "WARNING: '$SIGN_IDENTITY' not found; falling back to ad-hoc signing." >&2
    echo "         Run scripts/setup-signing-identity.sh so keychain grants persist." >&2
    codesign --force --deep --sign - "$APP"
fi
echo "$APP"
