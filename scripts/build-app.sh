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

codesign --force --deep --sign - "$APP"
echo "$APP"
