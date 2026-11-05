#!/bin/zsh
# Runs on GitHub (macOS runner), never on John's Mac: starts the iPhone app in the simulator on the sample calendars,
# runs its built-in checks, and takes a picture of each screen in light and dark. Usage: ios-check.sh <built .app> <picture folder>
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
[ -d "$APP" ] || { echo "no .app found"; exit 1; }
UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for k,v in d.items() if "iOS" in k for x in v if "iPhone" in x["name"]]
pick=[x for x in c if "16 Pro" in x["name"] and "Max" not in x["name"]] or c
print(pick[0]["udid"])')
echo "simulator $UDID"
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false   # the add screen shows the on-screen keyboard, as in the mockup
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl spawn "$UDID" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true || true   # no first-run keyboard tip over the keys
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 || true
xcrun simctl install "$UDID" "$APP"
BID=com.johnhesch.dateline
rc=0
echo "== built-in checks =="
for try in 1 2; do
  perl -e 'alarm 300; exec @ARGV' xcrun simctl launch --console --terminate-running-process "$UDID" $BID --selftest > "$OUT/selftest.txt" 2>&1 || true
  cat "$OUT/selftest.txt"
  grep -q "^DONE" "$OUT/selftest.txt" && break
  echo "-- the checks did not finish (try $try); crash reports:"
  for f in $(ls -t ~/Library/Logs/DiagnosticReports/DatelinePhone* 2>/dev/null | head -1); do head -c 3000 "$f"; done
done
grep -q "^DONE failures=0" "$OUT/selftest.txt" || rc=1
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  for s in list week day month year add details details2 tasks places email settings settings-accounts settings-accounts+icloud settings-sets settings-look settings-week settings-alerts settings-weather unlock widgets; do
    xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" $BID --sample -demo $s >/dev/null || rc=1
    case $s in places) sleep 12;; *) sleep 6;; esac   # the map needs its tiles
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$mode.png" >/dev/null 2>&1 || rc=1
  done
done
# Large text, as on John's phone: the week and day must still fit (TestFlight fixes 2026-11-05).
xcrun simctl ui "$UDID" appearance light
for size in extra-extra-large accessibility-large; do
  xcrun simctl ui "$UDID" content_size $size
  for s in list week day; do
    xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" $BID --sample -demo $s >/dev/null || rc=1
    sleep 6
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$size.png" >/dev/null 2>&1 || rc=1
  done
done
xcrun simctl ui "$UDID" content_size large
xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
ls -la "$OUT"
exit $rc
