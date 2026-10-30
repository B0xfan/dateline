#!/bin/zsh
# Wraps the release binary into "build/Dateline.app" with Sparkle.framework (self-update) inside, and signs it with John's free Apple Development identity (as CleanYard does), so Calendar and Reminders permission survive rebuilds; ad hoc signing made macOS ask again after every install. Run after `swift build -c release`.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Dateline.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
cp "$(swift build -c release --show-bin-path)/Dateline" "$APP/Contents/MacOS/Dateline"
cp App/Info.plist "$APP/Contents/Info.plist"
FW=$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)
[ -n "$FW" ] || { echo "Sparkle.framework not found under .build/artifacts: build first"; exit 1; }
SPK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$FW" "$SPK"   # ditto keeps the symlinks the signature depends on
# Dateline is not sandboxed, so Sparkle's helper services are not needed.
rm -rf "$SPK/XPCServices" "$SPK/Versions/B/XPCServices"
# Dateline is English only: Sparkle's other languages go, so every Mac shows the patched English wording.
find "$SPK/Versions/B/Resources" -maxdepth 1 -name '*.lproj' ! -name Base.lproj -exec rm -rf {} +
python3 -I scripts/patch-sparkle-strings.py "$SPK"
ID=AB33048703517BE9CB52B2E3781C8B1B00C8A64D
# On any other Mac (no such identity) sign ad hoc: it works, but macOS asks for permissions again after each update there.
security find-identity -v -p codesigning | grep -q "$ID" || ID=-
# Inside out: Sparkle's installer, its progress app, the framework, then the app. No --deep.
for part in "$SPK/Versions/B/Autoupdate" "$SPK/Versions/B/Updater.app" "$SPK" "$APP"; do codesign --force --sign "$ID" "$part"; done
echo "$APP"
