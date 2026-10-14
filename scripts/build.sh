#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/Dev Toolbox.app"
mkdir -p "$APP_DIR/Contents/MacOS"
swiftc -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -O "$PROJECT_DIR"/Sources/*.swift -o "$APP_DIR/Contents/MacOS/DevToolbox" -framework Cocoa -framework SwiftUI
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DevToolbox</string>
<key>CFBundleIdentifier</key><string>local.pc2mac.devtoolbox</string>
<key>CFBundleName</key><string>Dev Toolbox</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
