#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APPHARBOR_APP_PATH:-$REPO_ROOT/dist/AppHarbor.app}"
OUTPUT_ROOT="${APPHARBOR_OUTPUT_DIR:-$REPO_ROOT/dist}"

if [[ ! -d "$APP_PATH" ]]; then
    printf 'App bundle not found: %s\nBuild it first with Scripts/build-app.sh.\n' "$APP_PATH" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/AppHarbor")"
if [[ "$ARCHS" != arm64 ]]; then
    printf 'Expected an arm64 AppHarbor build, found: %s\n' "$ARCHS" >&2
    exit 1
fi

DMG_PATH="$OUTPUT_ROOT/AppHarbor-${VERSION}-arm64.dmg"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/private/tmp}/AppHarborDMG.XXXXXX")"
VOLUME_NAME="AppHarbor ${VERSION}"
trap 'rm -rf "$STAGING_ROOT"' EXIT

mkdir -p "$OUTPUT_ROOT" "$STAGING_ROOT/$VOLUME_NAME"
cp -R "$APP_PATH" "$STAGING_ROOT/$VOLUME_NAME/AppHarbor.app"
ln -s /Applications "$STAGING_ROOT/$VOLUME_NAME/Applications"
cat > "$STAGING_ROOT/$VOLUME_NAME/Installation.txt" <<NOTE
AppHarbor ${VERSION} (build ${BUILD})

Requires macOS 14 or later and an Apple Silicon Mac.

Drag AppHarbor.app to Applications, then open it from Applications.

This preview is ad-hoc signed and not notarized. If macOS blocks launch, see
Apple's instructions for apps from an unknown developer:
https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac
NOTE

rm -f "$DMG_PATH"
hdiutil create \
    -srcfolder "$STAGING_ROOT/$VOLUME_NAME" \
    -volname "$VOLUME_NAME" \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

printf 'Created %s\n' "$DMG_PATH"
