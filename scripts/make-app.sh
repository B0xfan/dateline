#!/bin/zsh
# Wraps the release binary into "build/Dateline.app" and signs it ad hoc (local use only). Run after `swift build -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Dateline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Dateline" "$APP/Contents/MacOS/Dateline"
cp App/Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "$APP"
