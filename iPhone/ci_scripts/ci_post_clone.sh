#!/bin/sh
# Xcode Cloud runs this after the clone in EVERY workflow. Only the "Mac check" workflow does anything here:
# the phone's Default (TestFlight) workflow must pass straight through, so this test comes first.
[ "$CI_WORKFLOW" = "Mac check" ] || exit 0
# The Mac app: release build and its self-test (pure logic, no calendar access), as in the GitHub build job.
set -eu
cd "$CI_PRIMARY_REPOSITORY_PATH"
swift build -c release
.build/release/Dateline --selftest
