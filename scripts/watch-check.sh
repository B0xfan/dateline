#!/bin/zsh
# Runs on GitHub (macOS runner), never on John's Mac: starts the watch app in the watch simulator on the sample calendars
# and takes a picture of each screen at the small, large and Ultra sizes. Usage: watch-check.sh <built watch .app> <picture folder>
set -u
APP="$1"; OUT="$2"; mkdir -p "$OUT"
[ -d "$APP" ] || { echo "no watch .app found"; exit 1; }
BID=com.johnhesch.dateline.watchkitapp
rc=0
# One simulator per size: the newest watch whose name has 41/42 mm, 45/46 mm and 49 mm.
xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
w=[(k,x) for k,v in d.items() if "watchOS" in k for x in v if "Watch" in x["name"]]
for label,mm in (("small",("41mm","42mm")),("large",("45mm","46mm")),("ultra",("49mm",))):
    c=[x for k,x in sorted(w,key=lambda e:e[0]) if any(m in x["name"] for m in mm)]
    print(label, c[-1]["udid"] if c else "-", (c[-1]["name"] if c else "none").replace(" ","_"))' > "$OUT/sims.txt"
cat "$OUT/sims.txt"
while read label udid name; do
  [ "$udid" = "-" ] && { echo "no $label watch simulator"; rc=1; continue; }
  xcrun simctl boot "$udid" || true
  xcrun simctl bootstatus "$udid" -b
  xcrun simctl status_bar "$udid" override --time 9:41 >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$APP" || { rc=1; continue; }
  for s in next today today-ticked details details-call add; do
    xcrun simctl terminate "$udid" $BID >/dev/null 2>&1 || true
    xcrun simctl launch "$udid" $BID --sample -demo $s >/dev/null || rc=1
    sleep 6
    xcrun simctl io "$udid" screenshot "$OUT/$s-$label.png" >/dev/null 2>&1 || rc=1
  done
  # The leave-now alert as the watch shows it (a made-up alert with the same words and buttons the drive planner uses).
  xcrun simctl terminate "$udid" $BID >/dev/null 2>&1 || true
  cat > "$OUT/leave.apns" <<JSON
{"Simulator Target Bundle":"$BID","aps":{"alert":{"title":"Time to leave for Lunch with Sam","body":"25 min drive to Café Playa. Leave now to arrive at 12:30."},"category":"leave"}}
JSON
  xcrun simctl push "$udid" $BID "$OUT/leave.apns" >/dev/null 2>&1 && { sleep 4; xcrun simctl io "$udid" screenshot "$OUT/leave-alert-$label.png" >/dev/null 2>&1; } || echo "leave alert picture not possible on $label"
  xcrun simctl shutdown "$udid" || true
done < "$OUT/sims.txt"
rm -f "$OUT/leave.apns"
ls -la "$OUT"
exit $rc
