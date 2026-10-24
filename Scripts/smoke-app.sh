#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APPHARBOR_APP_PATH:-$REPO_ROOT/dist/AppHarbor.app}"
[[ -x "$APP_PATH/Contents/MacOS/AppHarbor" ]]
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" | grep -qx 'com.appharbor.desktop'
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" | grep -qx '0.1.2'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" | grep -qx '3'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist" | grep -qx 'AppHarbor.icns'
[[ -s "$APP_PATH/Contents/Resources/AppHarbor.icns" ]]
ICONSET_PATH="$(mktemp -d /private/tmp/AppHarborIconSmoke.XXXXXX)"
trap 'rm -rf "$ICONSET_PATH"' EXIT
iconutil -c iconset -o "$ICONSET_PATH/AppHarbor.iconset" "$APP_PATH/Contents/Resources/AppHarbor.icns"
for icon in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    [[ -s "$ICONSET_PATH/AppHarbor.iconset/$icon" ]]
done
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_PATH/Contents/Info.plist" | grep -qx '14.0'
codesign --verify --deep --strict "$APP_PATH"
file "$APP_PATH/Contents/MacOS/AppHarbor"
printf 'App bundle metadata, all ten icon sizes, and ad-hoc signature verified.\n'
