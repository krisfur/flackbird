#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Keep Spotlight/LaunchServices away from build products: a registered
# iphonesimulator bundle shares the bundle ID and hijacks the Dock icon.
mkdir -p build && touch build/.metadata_never_index

xcodebuild -project SwiftFlac.xcodeproj -scheme SwiftFlac -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build build

# Known limitation: the macOS 26 Dock shows a placeholder icon for apps
# launched from build directories; the real icon appears when the app is
# run from /Applications or ~/Applications.
open "build/Build/Products/Debug/Flackbird.app"
