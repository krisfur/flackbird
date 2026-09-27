#!/usr/bin/env bash
# Captures README and App Store screenshots from simulators and the Mac app, using the
# generated demo library. Usage: ./take_screenshots.sh [ios|mac|qa|all]  (default: all)
#   or: ./take_screenshots.sh shot <device> <screen> <light|dark> <landscape 0|1> <file>
set -euo pipefail
cd "$(dirname "$0")"

WHAT="${1:-all}"
BUNDLE_ID="com.kfurman.SwiftFlac.dev2026"
LIBRARY="$PWD/build/demo-library"
OUT="$PWD/screenshots"
QA="$PWD/build/screenshot-qa"
IPHONE="iPhone 17 Pro Max"   # 1320x2868, the required 6.9-inch size
IPAD="iPad Pro 13-inch (M5)" # 2064x2752, the required 13-inch size
SETTLE=7

[[ -d "$LIBRARY" ]] || ./generate_demo_library.sh "$LIBRARY"
mkdir -p "$OUT" build && touch build/.metadata_never_index

udid() {
    xcrun simctl list devices available | grep -F "$1 (" | head -1 | grep -oE '[0-9A-F-]{36}'
}

build_ios() {
    xcodebuild -project SwiftFlac.xcodeproj -scheme SwiftFlac -configuration Debug \
        -destination "generic/platform=iOS Simulator" -derivedDataPath build/screenshots-ios \
        CODE_SIGNING_ALLOWED=NO build -quiet
}

# prepare <device name>: boots it with a clean install, the demo library, and an App Store status bar.
prepare() {
    local id
    id=$(udid "$1")
    # A fresh boot shows first-run notification banners; let them clear.
    if xcrun simctl boot "$id" 2>/dev/null; then
        xcrun simctl bootstatus "$id" -b >/dev/null
        sleep 25
    fi
    xcrun simctl status_bar "$id" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 >/dev/null
    xcrun simctl uninstall "$id" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl install "$id" build/screenshots-ios/Build/Products/Debug-iphonesimulator/SwiftFlac.app >/dev/null
    local documents
    documents="$(xcrun simctl get_app_container "$id" "$BUNDLE_ID" data)/Documents"
    mkdir -p "$documents"
    cp -R "$LIBRARY"/. "$documents"/
    echo "$id"
}

# shoot <udid> <screen> <appearance> <landscape 0|1> <output file>
shoot() {
    local id="$1" screen="$2" appearance="$3" landscape="$4" file="$5"
    xcrun simctl terminate "$id" "$BUNDLE_ID" 2>/dev/null || true
    # The killed instance's now-playing activity lingers in the Dynamic Island briefly.
    sleep 3
    xcrun simctl ui "$id" appearance "$appearance"
    SIMCTL_CHILD_SWIFTFLAC_SCREEN="$screen" SIMCTL_CHILD_SWIFTFLAC_APPEARANCE="$appearance" \
        SIMCTL_CHILD_SWIFTFLAC_LANDSCAPE="$landscape" xcrun simctl launch "$id" "$BUNDLE_ID" >/dev/null
    sleep "$SETTLE"
    xcrun simctl io "$id" screenshot "$file" >/dev/null 2>&1
    echo "  $(basename "$file")"
}

ios() {
    echo "iPhone: $IPHONE"
    local id
    id=$(prepare "$IPHONE")
    # README names: start, list, albums, details, search.
    for appearance in light dark; do
        shoot "$id" library "$appearance" 0 "$OUT/ios-start-$appearance.png"
        shoot "$id" folder "$appearance" 0 "$OUT/ios-list-$appearance.png"
        shoot "$id" albums "$appearance" 0 "$OUT/ios-albums-$appearance.png"
        shoot "$id" nowplaying "$appearance" 0 "$OUT/ios-details-$appearance.png"
        shoot "$id" search "$appearance" 0 "$OUT/ios-search-$appearance.png"
    done
    xcrun simctl shutdown "$id"
    echo "iPad: $IPAD"
    id=$(prepare "$IPAD")
    for appearance in light dark; do
        shoot "$id" albums "$appearance" 1 "$OUT/ipad-albums-$appearance.png"
        shoot "$id" folder "$appearance" 1 "$OUT/ipad-list-$appearance.png"
        shoot "$id" nowplaying "$appearance" 1 "$OUT/ipad-details-$appearance.png"
    done
    xcrun simctl shutdown "$id"
}

build_mac() {
    xcodebuild -project SwiftFlac.xcodeproj -scheme SwiftFlac -configuration Debug \
        -destination "platform=macOS" -derivedDataPath build/screenshots-mac \
        CODE_SIGNING_ALLOWED=NO build -quiet
    # Lists a process's on-screen windows, largest first: "id x y width height" in points.
    cat >build/window-bounds.swift <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1]) ?? 0
let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let windows = info.compactMap { window -> (Int, CGRect)? in
    guard window[kCGWindowOwnerPID as String] as? Int32 == pid, let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 50 else { return nil }
    return (id, rect)
}.sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
for (id, rect) in windows { print(id, Int(rect.minX), Int(rect.minY), Int(rect.width), Int(rect.height)) }
SWIFT
    swiftc -O build/window-bounds.swift -o build/window-bounds
}

# mac_shoot <screen> <appearance> <file>: the window, plus the now-playing popover when open,
# composited onto a 16:10 canvas (2560x1600 on Retina, 1280x800 otherwise).
mac_shoot() {
    local screen="$1" appearance="$2" file="$3" background
    [[ "$appearance" == dark ]] && background=0x1c1e22 || background=0xe6eaf0
    SWIFTFLAC_SCREEN="$screen" SWIFTFLAC_APPEARANCE="$appearance" SWIFTFLAC_LIBRARY="$LIBRARY" \
        build/screenshots-mac/Build/Products/Debug/SwiftFlac.app/Contents/MacOS/SwiftFlac >/dev/null 2>&1 &
    local pid=$!
    sleep "$SETTLE"
    local windows=() line
    while read -r line; do windows+=("$line"); done < <(build/window-bounds "$pid")
    [[ ${#windows[@]} -gt 0 ]] || { kill "$pid"; echo "no SwiftFlac window found" >&2; return 1; }
    local inputs=() filter="" index=0 main_x=0 main_y=0 scale=1 left=0 top=0 canvas_w=1280 canvas_h=800
    for line in "${windows[@]}"; do
        read -r id x y w h <<<"$line"
        local image="build/mac-window-$index.png"
        if ! screencapture -o -x -l "$id" "$image"; then
            kill "$pid" 2>/dev/null || true
            echo "Capture failed: give your terminal Screen Recording access in System Settings > Privacy & Security." >&2
            return 1
        fi
        local pixel_w pixel_h
        pixel_w=$(sips -g pixelWidth "$image" | awk '/pixelWidth/{print $2}')
        pixel_h=$(sips -g pixelHeight "$image" | awk '/pixelHeight/{print $2}')
        if [[ $index == 0 ]]; then
            # The main window is centred; anything else (the popover) keeps its offset from it.
            main_x=$x main_y=$y scale=$((pixel_w / w))
            canvas_w=$((1280 * scale)) canvas_h=$((800 * scale))
            left=$(((canvas_w - pixel_w) / 2)) top=$(((canvas_h - pixel_h) / 2))
            filter="[0][1]overlay=$left:$top[v1]"
        else
            filter+=";[v$index][$((index + 1))]overlay=$((left + (x - main_x) * scale)):$((top + (y - main_y) * scale))[v$((index + 1))]"
        fi
        inputs+=(-i "$image")
        index=$((index + 1))
    done
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=$background:s=${canvas_w}x${canvas_h}" "${inputs[@]}" \
        -filter_complex "$filter" -map "[v$index]" -frames:v 1 "$file"
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "  $(basename "$file")"
}

mac() {
    echo "Mac"
    for appearance in light dark; do
        mac_shoot albums "$appearance" "$OUT/mac-albums-$appearance.png"
        mac_shoot nowplaying "$appearance" "$OUT/mac-details-$appearance.png"
        mac_shoot search "$appearance" "$OUT/mac-search-$appearance.png"
    done
}

# Layout checks in both orientations; not shipped.
qa() {
    mkdir -p "$QA"
    for device in "$IPHONE" "$IPAD" "iPad mini (A17 Pro)"; do
        echo "QA: $device"
        local id slug
        id=$(prepare "$device")
        slug=$(echo "$device" | tr -cs 'A-Za-z0-9' '-' | sed 's/-$//')
        # iPadOS ignores an app's rotation request (the device or window decides), so iPads
        # are checked in portrait only; rotate them by hand in Simulator.
        orientations="0 1"
        [[ "$device" == iPad* ]] && orientations="0"
        for screen in library albums folder nowplaying search; do
            for landscape in $orientations; do
                shoot "$id" "$screen" light "$landscape" "$QA/$slug-$screen-$([[ $landscape == 1 ]] && echo landscape || echo portrait).png"
            done
        done
        xcrun simctl shutdown "$id"
    done
}

case "$WHAT" in
    ios) build_ios && ios ;;
    mac) build_mac && mac ;;
    qa) build_ios && qa ;;
    all) build_ios && ios && qa && build_mac && mac ;;
    shot) build_ios && shoot "$(prepare "$2")" "$3" "$4" "$5" "$6" ;;
    *) echo "usage: $0 [ios|mac|qa|all] | shot <device> <screen> <appearance> <landscape> <file>" >&2; exit 1 ;;
esac
