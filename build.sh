#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

app="${1:-$HOME/Applications/Codex Usage.app}"
build="$(mktemp -d)"
trap 'rm -rf "$build"' EXIT
bundle="$build/Codex Usage.app"
mkdir -p "$bundle/Contents/MacOS"
sparkle="${CODEX_USAGE_SPARKLE_DIR:-}"
sparkle_flags=()
if [[ -n "$sparkle" ]]; then
    codesign --verify --deep --strict "$sparkle/Sparkle.framework"
    mkdir -p "$bundle/Contents/Frameworks"
    ditto "$sparkle/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
    sparkle_flags=(-D CODEX_USAGE_SPARKLE -F "$sparkle" -framework Sparkle
        -Xlinker -rpath -Xlinker '@executable_path/../Frameworks')
fi
compile() {
    swiftc -O -swift-version 5 -target "$1-apple-macosx14.0" \
        Main.swift Usage.swift Activity.swift Questions.swift CloudActivity.swift ${sparkle_flags[@]+"${sparkle_flags[@]}"} -o "$2"
}

if [[ "${CODEX_USAGE_UNIVERSAL:-0}" == 1 ]]; then
    compile arm64 "$build/CodexUsage-arm64"
    compile x86_64 "$build/CodexUsage-x86_64"
    lipo -create "$build/CodexUsage-arm64" "$build/CodexUsage-x86_64" \
        -output "$bundle/Contents/MacOS/CodexUsage"
else
    compile "$(uname -m)" "$bundle/Contents/MacOS/CodexUsage"
fi
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.aditya.codex-usage</string>
  <key>CFBundleName</key><string>Codex Usage</string>
  <key>CFBundleExecutable</key><string>CodexUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.3</string>
  <key>CFBundleVersion</key><string>4</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
if [[ -n "$sparkle" ]]; then
    plist="$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy \
        -c 'Add :SUFeedURL string https://raw.githubusercontent.com/AdiArya05/codex-usage-menu-bar/main/appcast.xml' \
        -c 'Add :SUPublicEDKey string RO6p/ssKvDSBRkwIJt2XNB/FbRyxuoHgmzg+wXu6yvQ=' \
        -c 'Add :SUEnableAutomaticChecks bool true' \
        -c 'Add :SUAutomaticallyUpdate bool true' \
        -c 'Add :SUVerifyUpdateBeforeExtraction bool true' \
        -c 'Add :SURequireSignedFeed bool true' "$plist"
fi
codesign --force --sign - "$bundle"
mkdir -p "$(dirname "$app")"
ditto "$bundle" "$app"
echo "$app"
