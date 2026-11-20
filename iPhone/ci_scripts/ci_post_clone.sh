#!/bin/sh
# Xcode Cloud runs this after the clone in EVERY workflow.
if [ "$CI_WORKFLOW" != "Mac check" ]; then
	# Phone upload: Apple closes a version number for uploads once it is on the App Store, so every
	# upload must carry a higher number than the live one. Raise it here instead of waiting for Apple's refusal.
	# shortcut: the public lookup lags an approval by up to a day; an upload in that window can still be refused.
	pbx="${CI_PRIMARY_REPOSITORY_PATH:-.}/iPhone/Dateline.xcodeproj/project.pbxproj"
	live=$(curl -fsS --max-time 20 "https://itunes.apple.com/lookup?id=6831255878" | plutil -extract results.0.version raw -o - - 2>/dev/null)
	proj=$(sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$pbx" | head -1)
	next=$(echo "$live $proj" | awk '{ split($1,l,"."); split($2,p,".");
		if ($1 == "" || p[1] > l[1] || (p[1] == l[1] && p[2] > l[2])) print ""; else print l[1] "." l[2]+1 }')
	if [ -n "$next" ]; then
		sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $next;/" "$pbx"
		echo "Phone version $proj is not above the App Store's $live: building as $next"
	else
		echo "Phone version $proj (App Store: ${live:-unknown})"
	fi
	exit 0
fi
# The Mac app: release build and its self-test (pure logic, no calendar access), as in the GitHub build job.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
swift build -c release
.build/release/Dateline --selftest
