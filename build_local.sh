#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
APP_NAME="Hangyeol"
APP_VERSION=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleShortVersionString" "$REPO_ROOT/Info.plist")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy \
    -c "Print :CFBundleVersion" "$REPO_ROOT/Info.plist")
PKG_OUTPUT="$REPO_ROOT/Hangyeol_${APP_VERSION}_Local.pkg"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hangyeol-local-package.XXXXXX")
PAYLOAD_DIR="$TEMP_DIR/Payload"
APP_BUNDLE="$PAYLOAD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
COMPONENT_PLIST="$TEMP_DIR/components.plist"
EXPANDED_DIR="$TEMP_DIR/Expanded"
RAW_PKG="$TEMP_DIR/Hangyeol.raw.pkg"
SCRIPTS_DIR="$TEMP_DIR/Scripts"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

cd "$REPO_ROOT"
swift build -c release --product "$APP_NAME"
swift build -c release --product HangyeolInstallerHelper

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp ".build/release/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp Info.plist "$CONTENTS_DIR/"
cp -R Resources/. "$RESOURCES_DIR/"
cp AppIcon.icns icon.tiff input-ko.tiff "$RESOURCES_DIR/"
cp -R ".build/release/Hangyeol_HangyeolCore.bundle" "$RESOURCES_DIR/"
find "$PAYLOAD_DIR" -name '._*' -delete
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
    | /usr/bin/awk -F'"' '/Apple Development:/{ print $2; exit }')
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "Apple Development signing identity not found." >&2
    exit 1
fi

codesign --force --options runtime --timestamp=none \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
find "$APP_BUNDLE" -name '._*' -delete
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
"$MACOS_DIR/$APP_NAME" --verify-launch
bash Tools/stage_package_scripts.sh \
    release \
    "$SCRIPTS_DIR" \
    "$SIGNING_IDENTITY"

pkgbuild --analyze --root "$PAYLOAD_DIR" "$COMPONENT_PLIST"
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"
plutil -replace 0.BundleHasStrictIdentifier -bool NO "$COMPONENT_PLIST"
pkgbuild --root "$PAYLOAD_DIR" \
    --component-plist "$COMPONENT_PLIST" \
    --install-location "/Library/Input Methods" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "com.thlim.hangyeol" \
    --version "$APP_VERSION" \
    "$RAW_PKG"

bash Tools/rebuild_clean_package.sh \
    "$RAW_PKG" \
    "$PAYLOAD_DIR" \
    "$SCRIPTS_DIR" \
    "$PKG_OUTPUT"

PAYLOAD_FILES=$(pkgutil --payload-files "$PKG_OUTPUT")
case "$PAYLOAD_FILES" in
    *"/._"*)
        echo "Package contains AppleDouble metadata files." >&2
        exit 1
        ;;
esac

pkgutil --expand-full "$PKG_OUTPUT" "$EXPANDED_DIR"
EXPANDED_APP=$(find "$EXPANDED_DIR" -type d -name "$APP_NAME.app" -print -quit)
if [ -z "$EXPANDED_APP" ]; then
    echo "Packaged app was not found during validation." >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$EXPANDED_APP"
EXPANDED_HELPER=$(find "$EXPANDED_DIR" -type f \
    -name HangyeolInstallerHelper -print -quit)
if [ -z "$EXPANDED_HELPER" ]; then
    echo "Packaged installer helper was not found during validation." >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$EXPANDED_HELPER"
SIGNATURE_DETAILS=$(codesign -dv --verbose=4 "$EXPANDED_APP" 2>&1)
case "$SIGNATURE_DETAILS" in
    *"Identifier=com.thlim.inputmethod.Hangyeol"*)
        ;;
    *)
        echo "Packaged app has an unexpected signing identifier." >&2
        exit 1
        ;;
esac
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$EXPANDED_APP/Contents/Info.plist")" = "$APP_VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$EXPANDED_APP/Contents/Info.plist")" = "$BUILD_NUMBER"

echo "Created $PKG_OUTPUT (version $APP_VERSION, build $BUILD_NUMBER)"
