#!/bin/bash
# Builds setPilot.app (ad-hoc signed) next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=setPilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/setPilot "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>setPilot</string>
  <key>CFBundleIdentifier</key><string>local.setpilot</string>
  <key>CFBundleName</key><string>setPilot</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSLocalNetworkUsageDescription</key><string>Talks to your WiZ bulb over UDP.</string>
</dict></plist>
PLIST
codesign --force -s - "$APP"
echo "Built $PWD/$APP"
