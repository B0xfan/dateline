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
  ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -5
  for f in $(ls -t ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i datelin | head -1); do cp ~/Library/Logs/DiagnosticReports/"$f" "$OUT/"; head -c 6000 ~/Library/Logs/DiagnosticReports/"$f"; done
done
grep -q "^DONE failures=0" "$OUT/selftest.txt" || rc=1
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  for s in list list-scrolled week week-sideways day month quarter year add search details details2 edit edit-invite drag resize undo-toast tap-new tasks task-edit task-edit-place task-new task-lists places email settings settings-accounts settings-accounts+icloud settings-sets settings-look settings-week settings-alerts settings-weather settings-subscribe settings-accounts+Subscribed+sub-sample unlock unlock-start widgets; do
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
  for s in list week day month quarter add details edit drag resize undo-toast tap-new task-edit task-new task-lists; do
    xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$UDID" $BID --sample -demo $s >/dev/null || rc=1
    sleep 6
    xcrun simctl io "$UDID" screenshot "$OUT/$s-$size.png" >/dev/null 2>&1 || rc=1
  done
done
xcrun simctl ui "$UDID" content_size large
xcrun simctl terminate "$UDID" $BID >/dev/null 2>&1 || true
# App Store pictures: Apple asks for the 6.9 inch size (1320 x 2868), so the largest Pro Max, light, sample calendars.
BIG=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=sorted((x["name"],[int(n) for n in k.split("iOS-")[-1].split("-")],x["udid"]) for k,v in d.items() if "iOS" in k for x in v if "Pro Max" in x["name"])
print(c[-1][2] if c else "")')  # newest Pro Max on its newest iOS
if [ -n "$BIG" ]; then
  mkdir -p "$OUT/store"
  xcrun simctl shutdown "$UDID" || true  # one simulator at a time on the runner
  xcrun simctl boot "$BIG" || true; xcrun simctl bootstatus "$BIG" -b
  xcrun simctl spawn "$BIG" defaults write com.apple.keyboard.preferences DidShowContinuousPathIntroduction -bool true || true
  xcrun simctl status_bar "$BIG" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 || true
  xcrun simctl install "$BIG" "$APP" || rc=1; xcrun simctl ui "$BIG" appearance light
  n=1
  for s in week add details tasks places; do
    xcrun simctl terminate "$BIG" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$BIG" $BID --sample -demo $s >/dev/null || rc=1
    case $s in places) sleep 12;; *) sleep 6;; esac
    xcrun simctl io "$BIG" screenshot "$OUT/store/$n-$s.png" >/dev/null 2>&1 || rc=1
    [ "$(sips -g pixelWidth "$OUT/store/$n-$s.png" 2>/dev/null | awk '/pixelWidth/{print $2}')" = 1320 ] || { echo "store picture $n-$s is not 6.9 inch (1320 wide)"; rc=1; }
    n=$((n+1))
  done
  xcrun simctl shutdown "$BIG" || true
else echo "no Pro Max simulator: no App Store pictures"; rc=1; fi
ls -la "$OUT"; [ -d "$OUT/store" ] && ls -la "$OUT/store"
exit $rc
