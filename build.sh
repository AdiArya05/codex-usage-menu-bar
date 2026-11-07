#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="${1:-$HOME/Applications/Codex Usage.app}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
bundle="$build/Codex Usage.app"
mkdir -p "$bundle/Contents/MacOS"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    Main.swift Usage.swift Activity.swift -o "$bundle/Contents/MacOS/CodexUsage"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.aditya.codex-usage</string>
  <key>CFBundleName</key><string>Codex Usage</string>
  <key>CFBundleExecutable</key><string>CodexUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
mkdir -p "$(dirname "$app")"
ditto "$bundle" "$app"
echo "$app"
