#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <raw-pkg> <payload-root> <scripts-dir|--no-scripts> <output-pkg>" >&2
    exit 64
fi

RAW_PKG=$1
PAYLOAD_ROOT=$2
SCRIPTS_DIR=$3
OUTPUT_PKG=$4
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hangyeol-clean-package.XXXXXX")
RAW_EXPANDED="$TEMP_DIR/RawExpanded"
ASSEMBLY_DIR="$TEMP_DIR/Assembly"
VERIFY_DIR="$TEMP_DIR/Verify"
CLEAN_PKG="$TEMP_DIR/Clean.pkg"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

for required_path in "$RAW_PKG" "$PAYLOAD_ROOT"; do
    if [ ! -e "$required_path" ]; then
        echo "Required package input does not exist: $required_path" >&2
        exit 1
    fi
done
if [ "$SCRIPTS_DIR" != "--no-scripts" ] && [ ! -d "$SCRIPTS_DIR" ]; then
    echo "Required package scripts do not exist: $SCRIPTS_DIR" >&2
    exit 1
fi

mkdir -p "$ASSEMBLY_DIR"
pkgutil --expand "$RAW_PKG" "$RAW_EXPANDED"

# macOS 26 may attach com.apple.provenance to every staging file. pkgbuild
# serializes those attributes as AppleDouble payload entries, so rebuild the
# BOM and cpio archives without any extended metadata.
lsbom "$RAW_EXPANDED/Bom" \
    | awk -F '\t' '$1 !~ /(^|\/)\._/' \
    > "$TEMP_DIR/clean-bom.list"
mkbom -i "$TEMP_DIR/clean-bom.list" "$ASSEMBLY_DIR/Bom"

PAYLOAD_FILE_COUNT=$(find "$PAYLOAD_ROOT" -print | wc -l | tr -d ' ')
PAYLOAD_INSTALL_KBYTES=$(find "$PAYLOAD_ROOT" \( -type f -o -type l \) \
    -exec stat -f '%z' {} + \
    | awk '{ total += $1 } END { print int((total + 1023) / 1024) }')
sed -E \
    "s#<payload numberOfFiles=\"[0-9]+\" installKBytes=\"[0-9]+\"/>#<payload numberOfFiles=\"$PAYLOAD_FILE_COUNT\" installKBytes=\"$PAYLOAD_INSTALL_KBYTES\"/>#" \
    "$RAW_EXPANDED/PackageInfo" \
    > "$ASSEMBLY_DIR/PackageInfo"
if ! grep -q \
    "<payload numberOfFiles=\"$PAYLOAD_FILE_COUNT\" installKBytes=\"$PAYLOAD_INSTALL_KBYTES\"/>" \
    "$ASSEMBLY_DIR/PackageInfo"; then
    echo "Failed to update clean package payload metadata." >&2
    exit 1
fi

archive_directory() {
    local source_dir=$1
    local archive_name=$2
    local cpio_path="$TEMP_DIR/${archive_name}.cpio"

    (
        cd "$source_dir"
        tar --format cpio \
            --no-acls \
            --no-fflags \
            --no-mac-metadata \
            --no-xattrs \
            --uid 0 \
            --gid 0 \
            --uname root \
            --gname wheel \
            -cf "$cpio_path" .
    )
    gzip -n -9 "$cpio_path"
    mv "${cpio_path}.gz" "$ASSEMBLY_DIR/$archive_name"
}

archive_directory "$PAYLOAD_ROOT" Payload
if [ "$SCRIPTS_DIR" != "--no-scripts" ]; then
    archive_directory "$SCRIPTS_DIR" Scripts
fi

(
    cd "$ASSEMBLY_DIR"
    if [ "$SCRIPTS_DIR" = "--no-scripts" ]; then
        xar --compression none -cf "$CLEAN_PKG" Bom PackageInfo Payload
    else
        xar --compression none -cf "$CLEAN_PKG" Bom PackageInfo Payload Scripts
    fi
)

PAYLOAD_FILES=$(pkgutil --payload-files "$CLEAN_PKG")
case "$PAYLOAD_FILES" in
    *"/._"*)
        echo "Rebuilt package still contains AppleDouble metadata files." >&2
        exit 1
        ;;
esac

pkgutil --expand-full "$CLEAN_PKG" "$VERIFY_DIR"
if find "$VERIFY_DIR" -name '._*' -print -quit | grep -q .; then
    echo "Rebuilt package expands with AppleDouble metadata files." >&2
    exit 1
fi

install -m 644 "$CLEAN_PKG" "$OUTPUT_PKG"
