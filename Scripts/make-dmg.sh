#!/bin/bash
# Builds a universal (Apple silicon + Intel) Release version of Paperless Drop and packs it
# into a .dmg with a SHA-256 checksum. The app is signed ad-hoc only, not with a Developer ID.
# Usage: Scripts/make-dmg.sh [output-directory]   (default: dist)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PaperlessDrop"
OUT="${1:-dist}"

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }

echo "Generating the Xcode project…"
xcodegen generate --quiet

echo "Building a universal Release version…"
xcodebuild build -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath build-release \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO -quiet

APP="build-release/Build/Products/Release/$APP_NAME.app"
[ -d "$APP" ] || { echo "Build failed: $APP not found" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "Version $VERSION, architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
codesign --verify --deep --strict "$APP"

STAGE=$(mktemp -d)
trap 'rm -rf "${STAGE:?}"' EXIT
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$OUT"
DMG="$APP_NAME-$VERSION.dmg"
rm -f "$OUT/$DMG" "$OUT/$DMG.sha256"
hdiutil create -volname "Paperless Drop" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$DMG" >/dev/null
(cd "$OUT" && shasum -a 256 "$DMG" > "$DMG.sha256")
echo "Created $OUT/$DMG"
cat "$OUT/$DMG.sha256"
