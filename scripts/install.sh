#!/bin/zsh
# The one install step: puts the locally built, signed app into /Applications (replacing an older copy) and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="build/Dateline.app"
DST="/Applications/Dateline.app"
[[ -d "$SRC" ]] || { echo "No build found. Run scripts/local-build.sh first."; exit 1; }
codesign --verify --strict "$SRC"
pkill -x Dateline 2>/dev/null && sleep 1 || true
STAGE="/Applications/.dateline-install"  # hidden folder: the copy is never seen under a temporary name like "Dateline.app.new" (macOS kept that name once)
rm -rf "$STAGE"; mkdir "$STAGE"
ditto "$SRC" "$STAGE/Dateline.app"  # copy first: a failed copy must not leave /Applications without the app
rm -rf "$DST"
mv "$STAGE/Dateline.app" "$DST"; rmdir "$STAGE"
open "$DST"
echo "Installed: $DST"
