#!/bin/zsh
# Wraps the release binary into "build/Dateline.app" and signs it with John's free Apple Development identity (as CleanYard does), so Calendar and Reminders permission survive rebuilds; ad hoc signing made macOS ask again after every install. Run after `swift build -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Dateline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Dateline" "$APP/Contents/MacOS/Dateline"
cp App/Info.plist "$APP/Contents/Info.plist"
ID=AB33048703517BE9CB52B2E3781C8B1B00C8A64D
# On any other Mac (no such identity) sign ad hoc: it works, but macOS asks for permissions again after each update there.
security find-identity -v -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "$ID" "$APP"
echo "$APP"
