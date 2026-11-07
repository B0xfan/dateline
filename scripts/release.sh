#!/bin/zsh
# Makes the next Dateline version that installed copies offer through Dateline > Check for Updates.
#   scripts/release.sh "Line one of what is new
#   Line two"            builds and checks everything, publishes NOTHING (dry run, files in build/release/)
#   scripts/release.sh "..." --publish    the same, then publishes the GitHub release (zip + appcast.xml)
# Runs on John's Mac: the signing identity lives only here. Builds locally, niced (scripts/local-build.sh).
# Needs: gh logged in, the update key file (Application Support/Dateline/update-signing.key, backup in Bitwarden: "Dateline update signing key").
# Other people's copies reach the update list only while the repo is public.
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES="${1:?Say what is new, in plain words, one line per change}"
PUBLISH=""; [ "${2:-}" = "--publish" ] && PUBLISH=1
REPO="B0xfan/dateline"
SUPPORT="$HOME/Library/Application Support/Dateline"
KEY="$SUPPORT/update-signing.key"
[ -f "$KEY" ] || { echo "Update key file missing: $KEY (backup: Bitwarden, 'Dateline update signing key')"; exit 1; }
[ -f "$SUPPORT/google_client.json" ] || { echo "Dateline's Google key missing: $SUPPORT/google_client.json (without it Google sign-in fails on buyers' Macs)"; exit 1; }

# Sparkle's signing tool, downloaded once and checked against a fixed fingerprint.
TOOLS="$SUPPORT/sparkle-tools-2.10.0"; SIGN_UPDATE="$TOOLS/bin/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
  mkdir -p "$TOOLS"; T=$(mktemp -d)
  curl -fsSL -o "$T/s.tar.xz" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
  [ "$(shasum -a 256 "$T/s.tar.xz" | cut -d' ' -f1)" = "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c" ] || { echo "Sparkle download does not match the expected fingerprint"; exit 1; }
  tar -xf "$T/s.tar.xz" -C "$TOOLS" bin; rm -rf "$T"
fi

# Next version: one more than the newest release (the first one is 0.1.2; copies installed before updates existed are build 1).
LAST=$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName')   # a login failure stops the script here; no releases yet gives an empty answer
N=$(( ${LAST##*.} + 1 )); [ -n "$LAST" ] || N=2
VER="0.1.$N"; TAG="v$VER"

[ -z "$(git status --porcelain -- Sources Package.swift Package.resolved App Icon scripts)" ] || { echo "Uncommitted or new app files: commit them first"; exit 1; }  # new files too, so every release matches a commit
scripts/local-build.sh >/dev/null

OUT=build/release; APP="$OUT/Dateline.app"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto build/Dateline.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $N" "$APP/Contents/Info.plist"
# Developer ID signing and Apple's check (notarizing) through Xcode's signed-in Apple account: the Developer ID certificate is held by Apple, so nothing goes in the keychain.
# First sign locally with hardened runtime and Dateline's permissions (Xcode keeps both when it re-signs), then let Xcode re-sign with Developer ID, embed the
# all-Macs profile (needed for the Focus permission) and send it to Apple; the checked, stapled app comes back into $APP.
ID=AB33048703517BE9CB52B2E3781C8B1B00C8A64D
security find-identity -v -p codesigning | grep -q "$ID" || { echo "Apple Development identity missing: Xcode > Settings > Accounts"; exit 1; }
SPK="$APP/Contents/Frameworks/Sparkle.framework"
for part in "$SPK/Versions/B/Autoupdate" "$SPK/Versions/B/Updater.app" "$SPK"; do codesign --force --options runtime --timestamp=none --sign "$ID" "$part"; done
codesign --force --options runtime --timestamp=none --entitlements App/Dateline.entitlements --sign "$ID" "$APP"
AR="$OUT/Dateline.xcarchive"; mkdir -p "$AR/Products/Applications"; mv "$APP" "$AR/Products/Applications/"
python3 -I - "$AR/Info.plist" "$VER" "$N" <<'PY2'
import sys, plistlib, datetime
out, ver, n = sys.argv[1:4]
plistlib.dump({"ArchiveVersion": 2, "Name": "Dateline", "SchemeName": "Dateline", "CreationDate": datetime.datetime.now(datetime.timezone.utc),
  "ApplicationProperties": {"ApplicationPath": "Applications/Dateline.app", "CFBundleIdentifier": "com.johnhesch.dateline",
  "CFBundleShortVersionString": ver, "CFBundleVersion": n, "Team": "LJZ32VB25F", "Architectures": ["arm64"]}}, open(out, "wb"))
PY2
cat > "$OUT/export.plist" <<'EOP'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>method</key><string>developer-id</string><key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>LJZ32VB25F</string><key>destination</key><string>upload</string></dict></plist>
EOP
taskpolicy -b nice -n 19 xcodebuild -exportArchive -archivePath "$AR" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/upload" -allowProvisioningUpdates >"$OUT/export.log" 2>&1 \
  || { tail -20 "$OUT/export.log"; echo "Sending to Apple's check failed (full log: $OUT/export.log)"; exit 1; }
echo "Sent to Apple's check; waiting for the answer (usually a few minutes)..."
for i in {1..60}; do   # up to 30 minutes
  xcodebuild -exportNotarizedApp -archivePath "$AR" -exportPath "$OUT/notarized" >"$OUT/notarized.log" 2>&1 && break
  grep -qi "invalid\|rejected" "$OUT/notarized.log" && { cat "$OUT/notarized.log"; echo "Apple's check refused the app"; exit 1; }
  [ $i = 60 ] && { tail -5 "$OUT/notarized.log"; echo "No answer from Apple's check after 30 minutes"; exit 1; }
  sleep 30
done
ditto "$OUT/notarized/Dateline.app" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 | grep -q "source=Notarized Developer ID" || { spctl -a -vvv -t exec "$APP"; echo "Not accepted as a checked Developer ID app"; exit 1; }
taskpolicy -b nice -n 19 "$APP/Contents/MacOS/Dateline" --selftest >/dev/null || { echo "The signed app does not open"; exit 1; }   # proves macOS accepts its permissions

ZIP="$OUT/Dateline-$VER.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"   # keeps the symlinks inside Sparkle.framework, which the signature needs
SIG=$("$SIGN_UPDATE" --ed-key-file "$KEY" -p "$ZIP"); LEN=$(stat -f %z "$ZIP")
python3 -I - "$OUT/appcast.xml" "$VER" "$N" "$SIG" "$LEN" "https://github.com/$REPO/releases/download/$TAG/Dateline-$VER.zip" "$NOTES" <<'PY'
import sys, html, email.utils
out, ver, n, sig, ln, url, notes = sys.argv[1:8]
li = "".join("<li>%s</li>" % html.escape(l.strip()) for l in notes.splitlines() if l.strip())
open(out, "w").write(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Dateline</title>
    <item>
      <title>Version {ver}</title>
      <sparkle:version>{n}</sparkle:version>
      <sparkle:shortVersionString>{ver}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <description><![CDATA[<ul>{li}</ul>]]></description>
      <enclosure url="{url}" sparkle:edSignature="{sig}" length="{ln}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
''')
PY

# Check the finished package the way an installed copy will: unpack, signature intact, version right, update signature matches the key inside the app.
V=$(mktemp -d); trap 'rm -rf "$V"' EXIT
ditto -x -k "$ZIP" "$V"; VAPP="$V/Dateline.app"
codesign --verify --deep --strict "$VAPP"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$VAPP/Contents/Info.plist")" = "$N" ] || { echo "Version check failed"; exit 1; }
PUB=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$VAPP/Contents/Info.plist")
# Its own Python for this check, kept beside the Sparkle tools, because a Homebrew Python upgrade loses installed packages.
CHECK_PY="$SUPPORT/release-python/bin/python3"
"$CHECK_PY" -c 'import cryptography' 2>/dev/null || { /usr/bin/python3 -m venv --clear "$SUPPORT/release-python"; "$CHECK_PY" -m pip install -q cryptography; }
"$CHECK_PY" -I - "$PUB" "$SIG" "$ZIP" <<'PY'
import sys, base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[1])).verify(base64.b64decode(sys.argv[2]), open(sys.argv[3], "rb").read())
PY
echo "Checked: $ZIP (version $VER, build $N)"

# The disk image buyers open (drag Dateline onto Applications), checked by Apple and stapled. Updates still use the zip.
# Signed with the local Developer ID identity (key + certificate in the login keychain; key file and certificate kept in Application Support/Dateline/devid).
DEVID="Developer ID Application: John Hesch (LJZ32VB25F)"
security find-identity -v -p codesigning | grep -q "$DEVID" || { echo "Developer ID identity missing: $DEVID"; exit 1; }
ASC_KEY=S93537G5A5; ASC_P8="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY.p8"
ISS="${ASC_ISSUER_ID:-$( { grep '^ASC_ISSUER_ID=' "$HOME/Projects/A4/.env" 2>/dev/null || true; } | cut -d= -f2- | tr -d '"')}"
[ -f "$ASC_P8" ] && [ -n "$ISS" ] || { echo "App Store Connect key or issuer missing: $ASC_P8, ASC_ISSUER_ID"; exit 1; }
DMG="$OUT/Dateline.dmg"; ST="$OUT/dmg-stage"; rm -rf "$ST" "$DMG"; mkdir -p "$ST"
ditto "$VAPP" "$ST/Dateline.app"; ln -s /Applications "$ST/Applications"
hdiutil create -quiet -volname Dateline -srcfolder "$ST" -fs HFS+ -format UDZO "$DMG"; rm -rf "$ST"
codesign --sign "$DEVID" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key "$ASC_P8" --key-id "$ASC_KEY" --issuer "$ISS" --wait --timeout 30m | grep -q "status: Accepted" || { echo "Apple did not accept the disk image"; exit 1; }
xcrun stapler staple -q "$DMG"
spctl -a -t open --context context:primary-signature "$DMG" || { echo "The disk image is not accepted as signed and checked"; exit 1; }
echo "Checked: $DMG"

if [ -z "$PUBLISH" ]; then echo "Dry run: nothing published. Files are in $OUT/. Add --publish to release it."; exit 0; fi
# Atomic: draft first, attach the files, publish last. Any failure deletes the draft, so releases/latest never points at a release without an appcast.
DRAFTED=""; trap 'rm -rf "$V"; [ -z "$DRAFTED" ] || gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true' EXIT
DRAFTED=1
cp "$ZIP" "$OUT/Dateline.zip"   # same file under a name that never changes: releases/latest/download/Dateline.zip is the link the website gives buyers; Payhip links Dateline.dmg
gh release create "$TAG" "$ZIP" "$OUT/Dateline.zip" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --draft --title "Dateline $VER" --notes "$NOTES"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
DRAFTED=""   # published: a failed check below must not delete a live release
for i in 1 2 3 4 5 6; do
  curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" | grep -q "<sparkle:version>$N<" && { echo "Published $TAG: the update list now offers it."; exit 0; }
  sleep 5
done
echo "Published, but the update list URL does not show it yet: check it"; exit 1
