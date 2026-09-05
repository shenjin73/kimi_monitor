#!/bin/bash
# Build KimiMonitor.app without Xcode (requires Xcode Command Line Tools / swiftc).
set -euo pipefail
cd "$(dirname "$0")"

APP="KimiMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/KimiMonitor" \
    $(find app -name '*.swift' | sort)

cp app/Info.plist "$APP/Contents/Info.plist"

echo "Built $APP — run with: open $APP"
