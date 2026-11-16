#!/bin/bash
# Builds a Release version of Paperless Drop and installs it into ~/Applications.
# Run it again to update; a running copy is asked to quit first.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="PaperlessDrop"
BUNDLE_ID="de.jonas.PaperlessDrop"
DEST="$HOME/Applications/$APP_NAME.app"

command -v xcodegen >/dev/null || { echo "XcodeGen is required: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "Xcode is required (xcodebuild not found)" >&2; exit 1; }

echo "Generating the Xcode project…"
xcodegen generate --quiet

echo "Building (Release)…"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build -quiet build

BUILT="build/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "Build failed: $BUILT not found" >&2; exit 1; }

# The app asks before quitting while uploads are running, so give it a moment.
if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Quitting the running app…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null || break
        sleep 0.5
    done
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "The app is still running (unfinished uploads?). Quit it and run this script again." >&2
        exit 1
    fi
fi

mkdir -p "$HOME/Applications"
rm -rf "${DEST:?}"
ditto "$BUILT" "$DEST"
echo "Installed to $DEST"
open "$DEST"
echo "Click the menu bar icon, then the gear, to enter your Paperless URL and API token."
