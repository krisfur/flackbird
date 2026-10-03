#!/bin/bash
# Regenerates the AppIcon asset catalog images, and the About screen's copy, from swiftflac-icon.svg.
set -euo pipefail
cd "$(dirname "$0")"

SVG=swiftflac-icon.svg
OUT=SwiftFlac/Assets.xcassets/AppIcon.appiconset
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The source SVG must have a square canvas (currently 600x600).
cp "$SVG" "$TMP/icon.svg"

qlmanage -t -s 1024 "$TMP/icon.svg" -o "$TMP" >/dev/null
cp "$TMP/icon.svg.png" "$OUT/icon_1024.png"

# macOS icon size ladder; iOS uses the single 1024 image.
for s in 16 32 64 128 256 512; do
    sips -z $s $s "$OUT/icon_1024.png" --out "$OUT/icon_$s.png" >/dev/null
done

# Settings > About shows this copy; the app icon itself isn't loadable as an image at runtime.
cp "$OUT/icon_256.png" SwiftFlac/Assets.xcassets/AboutIcon.imageset/icon_256.png

echo "Icon assets regenerated in $OUT"
