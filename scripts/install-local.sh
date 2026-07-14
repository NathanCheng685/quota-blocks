#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP_NAME="Quota Blocks.app"
SOURCE_APP="$ROOT/dist/$APP_NAME"
TARGET_APP="/Applications/$APP_NAME"

"$ROOT/scripts/build-app.sh"

killall QuotaBlocks 2>/dev/null || true
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
open "$TARGET_APP"

echo "Installed $TARGET_APP"
