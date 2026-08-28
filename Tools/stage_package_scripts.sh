#!/bin/bash

set -euo pipefail
export COPYFILE_DISABLE=1

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <debug|release> <output-dir> <signing-identity>" >&2
    exit 64
fi

BUILD_CONFIGURATION=$1
OUTPUT_DIR=$2
SIGNING_IDENTITY=$3
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HELPER_SOURCE="$REPO_ROOT/.build/$BUILD_CONFIGURATION/HangyeolInstallerHelper"

case "$BUILD_CONFIGURATION" in
    debug|release)
        ;;
    *)
        echo "Unsupported build configuration: $BUILD_CONFIGURATION" >&2
        exit 64
        ;;
esac

if [ -e "$OUTPUT_DIR" ]; then
    echo "Package scripts output already exists: $OUTPUT_DIR" >&2
    exit 1
fi
if [ ! -x "$HELPER_SOURCE" ]; then
    echo "Built installer helper does not exist: $HELPER_SOURCE" >&2
    exit 1
fi

/bin/mkdir -p "$OUTPUT_DIR"
/bin/cp -R "$REPO_ROOT/Packaging/scripts/." "$OUTPUT_DIR/"
/usr/bin/install -m 755 "$HELPER_SOURCE" \
    "$OUTPUT_DIR/HangyeolInstallerHelper"
/bin/chmod 755 \
    "$OUTPUT_DIR/preinstall" \
    "$OUTPUT_DIR/postinstall" \
    "$OUTPUT_DIR/postinstall_classification.sh"
/usr/bin/xattr -cr "$OUTPUT_DIR"

case "$SIGNING_IDENTITY" in
    "Apple Development:"*)
        TIMESTAMP_ARGUMENT="--timestamp=none"
        ;;
    *)
        TIMESTAMP_ARGUMENT="--timestamp"
        ;;
esac

/usr/bin/codesign --force --options runtime "$TIMESTAMP_ARGUMENT" \
    --sign "$SIGNING_IDENTITY" \
    "$OUTPUT_DIR/HangyeolInstallerHelper"
/usr/bin/codesign --verify --strict --verbose=2 \
    "$OUTPUT_DIR/HangyeolInstallerHelper"

if /usr/bin/find "$OUTPUT_DIR" -name '._*' -print -quit \
    | /usr/bin/grep -q .; then
    echo "Package scripts contain AppleDouble metadata files." >&2
    exit 1
fi
