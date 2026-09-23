#!/bin/bash
set -e
export COPYFILE_DISABLE=1

# Define variables
APP_NAME="Hangyeol"
BUILD_DIR=".build/debug"
LEGACY_PAYLOAD_DIR="Packaging/Payload"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/hangyeol-debug-payload.XXXXXX")
PAYLOAD_DIR="$TMP_ROOT/Payload"
INSTALL_DIR="/Library/Input Methods"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${PAYLOAD_DIR}/${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
PKG_OUTPUT="Hangyeol_Debug.pkg"
COMPONENT_PLIST="Hangyeol_components.plist"
APP_SIGN="Developer ID Application: Chanwoo Park (M4U438VG59)"
PKG_SIGN="Developer ID Installer: Chanwoo Park (M4U438VG59)"
KEYCHAIN_PROFILE="HangyeolNotary"
RAW_PKG="$TMP_ROOT/Hangyeol_Debug.raw.pkg"
CLEAN_PKG="$TMP_ROOT/Hangyeol_Debug.unsigned.pkg"
SCRIPTS_DIR="$TMP_ROOT/Scripts"

cleanup() {
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$PAYLOAD_DIR/$APP_BUNDLE" >/dev/null 2>&1 || true
    rm -rf "$TMP_ROOT"
    rm -f "$COMPONENT_PLIST"
}
trap cleanup EXIT

echo "=========================================="
echo "    Hangyeol Debug Build & Notarization    "
echo "=========================================="

echo "[1/6] Building debug..."
swift build -c debug
swift build -c debug --product HangyeolInstallerHelper

echo "[2/6] Creating bundle structure..."
if [ -d "$LEGACY_PAYLOAD_DIR/$APP_BUNDLE" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$LEGACY_PAYLOAD_DIR/$APP_BUNDLE" >/dev/null 2>&1 || true
fi
rm -rf "$LEGACY_PAYLOAD_DIR"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable and Info.plist
cp "$BUILD_DIR/Hangyeol" "$MACOS_DIR/$APP_NAME"
cp Info.plist "$CONTENTS_DIR/"

# Copy resources
cp -R Resources/* "$RESOURCES_DIR/" 2>/dev/null || true
cp "AppIcon.icns" "$RESOURCES_DIR/" 2>/dev/null || true
cp "icon.tiff" "$RESOURCES_DIR/" 2>/dev/null || true
cp "input-ko.tiff" "$RESOURCES_DIR/" 2>/dev/null || true
if [ -d "$BUILD_DIR/Hangyeol_HangyeolCore.bundle" ]; then
    cp -R "$BUILD_DIR/Hangyeol_HangyeolCore.bundle" "$RESOURCES_DIR/"
fi
find "$PAYLOAD_DIR" -name '._*' -delete
xattr -cr "$PAYLOAD_DIR/$APP_BUNDLE" 2>/dev/null || true

echo "[3/6] Code Signing the .app bundle..."
codesign --force --options runtime --timestamp \
  --sign "$APP_SIGN" "$PAYLOAD_DIR/$APP_BUNDLE"
find "$PAYLOAD_DIR/$APP_BUNDLE" -name '._*' -delete
xattr -cr "$PAYLOAD_DIR/$APP_BUNDLE" 2>/dev/null || true

echo "Verifying App Signature..."
codesign -vv -d "$PAYLOAD_DIR/$APP_BUNDLE"
bash Tools/stage_package_scripts.sh \
    debug \
    "$SCRIPTS_DIR" \
    "$APP_SIGN" \
    "$PAYLOAD_DIR/$APP_BUNDLE"

APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
PKG_VERSION="${APP_VERSION}-debug"

echo "[4/6] Building the PKG installer..."
pkgbuild --analyze --root "$PAYLOAD_DIR" "$COMPONENT_PLIST"
plutil -replace 0.BundleIsRelocatable -bool NO "$COMPONENT_PLIST"
plutil -replace 0.BundleHasStrictIdentifier -bool NO "$COMPONENT_PLIST"

pkgbuild --root "$PAYLOAD_DIR" \
         --component-plist "$COMPONENT_PLIST" \
         --install-location "$INSTALL_DIR" \
         --scripts "$SCRIPTS_DIR" \
         --identifier "com.thlim.hangyeol" \
         --version "$PKG_VERSION" \
         "$RAW_PKG"

bash Tools/rebuild_clean_package.sh \
    "$RAW_PKG" \
    "$PAYLOAD_DIR" \
    "$SCRIPTS_DIR" \
    "$CLEAN_PKG"
rm -f "$PKG_OUTPUT"
productsign --sign "$PKG_SIGN" "$CLEAN_PKG" "$PKG_OUTPUT"

if pkgutil --payload-files "$PKG_OUTPUT" | grep -E '(^|/)\._' >/dev/null; then
    echo "Error: signed package contains AppleDouble metadata files." >&2
    exit 1
fi
pkgutil --check-signature "$PKG_OUTPUT"

echo "[5/6] Submitting for Notarization..."
xcrun notarytool submit "$PKG_OUTPUT" --keychain-profile "$KEYCHAIN_PROFILE" --wait

echo "[6/6] Stapling Notarization Ticket..."
xcrun stapler staple "$PKG_OUTPUT"
xcrun stapler validate "$PKG_OUTPUT"
pkgutil --check-signature "$PKG_OUTPUT"
spctl -a -vv -t install "$PKG_OUTPUT"

echo "=========================================="
echo "    Done! Debug PKG is ready and notarized."
echo "    File: $PKG_OUTPUT"
echo "=========================================="
