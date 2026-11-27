#!/bin/zsh
# Packs the desktop widgets (Widgets/, built by `swift build -c release`) into <app>/Contents/PlugIns/DatelineWidgets.appex and signs
# them sandboxed with the app group (App/Widgets.entitlements). Usage: pack-widgets.sh <Dateline.app> <signing identity> [extra codesign flags]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$1"; ID="$2"; shift 2
BIN="$(swift build -c release --show-bin-path)"
EX="$APP/Contents/PlugIns/DatelineWidgets.appex"
rm -rf "$EX"; mkdir -p "$EX/Contents/MacOS" "$EX/Contents/Resources"
cp "$BIN/DatelineWidgets" "$EX/Contents/MacOS/DatelineWidgets"
cp App/WidgetsInfo.plist "$EX/Contents/Info.plist"
for k in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$k $(/usr/libexec/PlistBuddy -c "Print :$k" "$APP/Contents/Info.plist")" "$EX/Contents/Info.plist"
done
# The calendar set picker and the tick and Add buttons are App Intents: macOS finds them only through Metadata.appintents,
# which Xcode makes and SwiftPM does not, so make it here from the compiler's constant values.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
print -r -- "$PWD/Widgets/DatelineWidgets.swift" > "$T/src"
find "$BIN/../.." -path '*Release*DatelineWidgets*' -name '*.swiftconstvalues' 2>/dev/null | sed "s|^\([^/]\)|$PWD/\1|" > "$T/cv"
[ -s "$T/cv" ] || { echo "no constant values for DatelineWidgets: build with swift build -c release first"; exit 1; }
xcrun appintentsmetadataprocessor --output "$EX/Contents/Resources" --toolchain-dir "$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain" \
  --module-name DatelineWidgets --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
  --platform-family macOS --deployment-target 14.0 --target-triple "$(uname -m)-apple-macos14.0" \
  --source-file-list "$T/src" --swift-const-vals-list "$T/cv" --binary-file "$EX/Contents/MacOS/DatelineWidgets" >"$T/log" 2>&1 || { cat "$T/log"; exit 1; }
[ -f "$EX/Contents/Resources/Metadata.appintents/extract.actionsdata" ] || { cat "$T/log"; echo "no App Intents metadata"; exit 1; }
codesign --force "$@" --entitlements App/Widgets.entitlements --sign "$ID" "$EX"
