#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_PATH="${APPHARBOR_BUILD_SCRATCH:-/private/tmp/AppHarborBuild}"
OUTPUT_ROOT="${APPHARBOR_OUTPUT_DIR:-$REPO_ROOT/dist}"
APP_PATH="$OUTPUT_ROOT/AppHarbor.app"

cd "$REPO_ROOT"
swift "$REPO_ROOT/Scripts/generate-icon.swift"
test -s "$REPO_ROOT/Resources/AppHarbor.icns"
SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/private/tmp/AppHarborModuleCache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/AppHarborClangCache}" \
swift build --configuration release --product AppHarbor --scratch-path "$SCRATCH_PATH"
BIN_PATH="$(SWIFT_MODULECACHE_PATH="${SWIFT_MODULECACHE_PATH:-/private/tmp/AppHarborModuleCache}" \
CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/AppHarborClangCache}" \
swift build --configuration release --product AppHarbor --scratch-path "$SCRATCH_PATH" --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/AppHarbor" "$APP_PATH/Contents/MacOS/AppHarbor"
cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>AppHarbor</string>
    <key>CFBundleIdentifier</key><string>com.appharbor.desktop</string>
    <key>CFBundleName</key><string>AppHarbor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.2</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>CFBundleIconFile</key><string>AppHarbor.icns</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
cp "$REPO_ROOT/Resources/AppHarbor.icns" "$APP_PATH/Contents/Resources/AppHarbor.icns"
test -s "$APP_PATH/Contents/Resources/AppHarbor.icns"
codesign --force --deep --sign - "$APP_PATH"
printf 'Built %s\n' "$APP_PATH"
