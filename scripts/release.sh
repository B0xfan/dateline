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

[ -z "$(git status --porcelain -- Sources Package.swift Package.resolved App scripts)" ] || { echo "Uncommitted or new app files: commit them first"; exit 1; }  # new files too, so every release matches a commit
scripts/local-build.sh >/dev/null

OUT=build/release; APP="$OUT/Dateline.app"
rm -rf "$OUT"; mkdir -p "$OUT"
ditto build/Dateline.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" -c "Set :CFBundleVersion $N" "$APP/Contents/Info.plist"
ID=AB33048703517BE9CB52B2E3781C8B1B00C8A64D
security find-identity -v -p codesigning | grep -q "$ID" || ID=-
codesign --force --sign "$ID" "$APP"   # the version change breaks the app's outer signature; Sparkle inside stays signed
codesign --verify --deep --strict --verbose=2 "$APP"

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
python3 -I - "$PUB" "$SIG" "$ZIP" <<'PY'
import sys, base64
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
Ed25519PublicKey.from_public_bytes(base64.b64decode(sys.argv[1])).verify(base64.b64decode(sys.argv[2]), open(sys.argv[3], "rb").read())
PY
echo "Checked: $ZIP (version $VER, build $N)"

if [ -z "$PUBLISH" ]; then echo "Dry run: nothing published. Files are in $OUT/. Add --publish to release it."; exit 0; fi
# Atomic: draft first, attach both files, publish last. Any failure deletes the draft, so releases/latest never points at a release without an appcast.
DRAFTED=""; trap 'rm -rf "$V"; [ -z "$DRAFTED" ] || gh release delete "$TAG" --repo "$REPO" --yes --cleanup-tag >/dev/null 2>&1 || true' EXIT
DRAFTED=1
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --draft --title "Dateline $VER" --notes "$NOTES"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
DRAFTED=""   # published: a failed check below must not delete a live release
for i in 1 2 3 4 5 6; do
  curl -fsSL "https://github.com/$REPO/releases/latest/download/appcast.xml" | grep -q "<sparkle:version>$N<" && { echo "Published $TAG: the update list now offers it."; exit 0; }
  sleep 5
done
echo "Published, but the update list URL does not show it yet: check it"; exit 1
