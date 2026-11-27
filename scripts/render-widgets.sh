#!/bin/zsh
# Picture check for the widgets: draws all five in every size, light and dark, into the folder given (default build/widget-pictures).
# Needs a debug build first (swift build --product DatelineWidgets).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/widget-pictures}"; mkdir -p "$OUT"
D=.build/out/Products/Debug
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
taskpolicy -b nice -n 19 swiftc -parse-as-library -D RENDER -I "$D" "$D/DatelineCore.o" -target "$(uname -m)-apple-macos14.0" \
  Widgets/DatelineWidgets.swift scripts/render/main.swift -o "$T/render"
"$T/render" "$OUT"
ls "$OUT"
