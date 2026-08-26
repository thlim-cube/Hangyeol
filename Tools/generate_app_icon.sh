#!/bin/bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hangyeol-icon.XXXXXX")
ICONSET_DIR="$TEMP_DIR/Hangyeol.iconset"
MASTER_PNG="$TEMP_DIR/Hangyeol-1024.png"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

mkdir -p "$ICONSET_DIR"
/usr/bin/swift "$REPO_ROOT/Tools/generate_app_icon.swift" "$MASTER_PNG"

for spec in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"; do
    set -- $spec
    /usr/bin/sips -z "$1" "$1" "$MASTER_PNG" \
        --out "$ICONSET_DIR/$2" >/dev/null
done

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$REPO_ROOT/AppIcon.icns"
echo "Generated $REPO_ROOT/AppIcon.icns"
