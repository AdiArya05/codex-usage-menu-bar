#!/bin/bash
set -euo pipefail

if [[ $# != 3 || "$1" != "Developer ID Application: "* ]]; then
    echo "Usage: $0 'Developer ID Application: Name (TEAMID)' notary-profile output.zip" >&2
    exit 2
fi

identity="$1"
profile="$2"
output="$3"
if [[ -e "$output" ]]; then
    echo "Choose a new output path. A file already exists at $output." >&2
    exit 2
fi

if ! security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null; then
    echo "Developer ID Application identity with a private key is unavailable." >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
app="$work/Codex Usage.app"
CODEX_USAGE_UNIVERSAL=1 "$(dirname "$0")/build.sh" "$app"

codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$work/for-notarization.zip"
xcrun notarytool submit "$work/for-notarization.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$work/Codex-Usage-macOS.zip"
mv -n "$work/Codex-Usage-macOS.zip" "$output"
if [[ -e "$work/Codex-Usage-macOS.zip" ]]; then
    echo "The release ZIP was not written to $output." >&2
    exit 1
fi
echo "$output"
