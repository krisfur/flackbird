#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Drop a Music/ folder (subfolders = playlists) next to this script to
# have it seeded into the simulator app's Documents; it is gitignored.
MUSIC_DIR="${MUSIC_DIR:-$PWD/Music}"

# Pick a booted iPhone simulator if there is one, otherwise the first available iPhone.
UDID=$(xcrun simctl list devices booted | grep -m1 "iPhone" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' || true)
if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices available | grep -m1 "iPhone" | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')
fi
echo "Using simulator $UDID"

xcrun simctl boot "$UDID" 2>/dev/null || true
# Xcode 27 replaced Simulator.app with DeviceHub.app.
open -a DeviceHub 2>/dev/null || open -a Simulator

# Keep Spotlight/LaunchServices away from build products: a registered
# iphonesimulator bundle shares the bundle ID and hijacks the Dock icon.
mkdir -p build && touch build/.metadata_never_index

xcodebuild -project SwiftFlac.xcodeproj -scheme SwiftFlac -configuration Debug \
    -destination "id=$UDID" -derivedDataPath build build

APP="build/Build/Products/Debug-iphonesimulator/Flackbird.app"
xcrun simctl install "$UDID" "$APP"
# Read from the build so it follows APP_BUNDLE_IDENTIFIER.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

# Seed test music into the app's Documents folder (folders become playlists).
if [ -d "$MUSIC_DIR" ]; then
    CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
    rsync -a "$MUSIC_DIR/" "$CONTAINER/Documents/"
    echo "Seeded music from $MUSIC_DIR"
fi

xcrun simctl launch "$UDID" "$BUNDLE_ID"
