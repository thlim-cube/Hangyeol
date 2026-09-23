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
APP_BUNDLE="$TEMP_DIR/Build/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
UPDATER_DIR="$PAYLOAD_DIR/Library/Application Support/Hangyeol/Updater"
LAUNCH_DAEMONS_DIR="$PAYLOAD_DIR/Library/LaunchDaemons"
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
find "$APP_BUNDLE" -name '._*' -delete
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

# PackageKit only receives opaque update data. The registered input-method
# bundle is left untouched throughout the current login session.
mkdir -p "$UPDATER_DIR" "$LAUNCH_DAEMONS_DIR"
/usr/bin/install -m 755 .build/release/HangyeolInstallerHelper "$UPDATER_DIR/HangyeolInstallerHelper"
codesign --force --options runtime --timestamp=none \
    --sign "$SIGNING_IDENTITY" "$UPDATER_DIR/HangyeolInstallerHelper"
mkdir -p "$SCRIPTS_DIR"
/usr/bin/install -m 755 Packaging/scripts/postinstall_session "$SCRIPTS_DIR/postinstall"
(
    cd "$TEMP_DIR/Build"
    /usr/bin/tar --format ustar --no-acls --no-fflags \
        --no-mac-metadata --no-xattrs \
        --uid 0 --gid 0 --uname root --gname wheel \
        -czf "$UPDATER_DIR/pending-app.tar.gz" "$APP_NAME.app"
)
/usr/bin/shasum -a 256 "$UPDATER_DIR/pending-app.tar.gz" \
    > "$UPDATER_DIR/pending-app.sha256"
/usr/bin/install -m 755 Packaging/scripts/apply_staged_update.sh \
    "$UPDATER_DIR/apply_staged_update.sh"
/usr/bin/install -m 644 \
    Packaging/scripts/com.thlim.hangyeol.apply-staged-update.plist \
    "$LAUNCH_DAEMONS_DIR/com.thlim.hangyeol.apply-staged-update.plist"
/usr/bin/plutil -lint \
    "$LAUNCH_DAEMONS_DIR/com.thlim.hangyeol.apply-staged-update.plist"

pkgbuild --root "$PAYLOAD_DIR" \
    --install-location "/" \
    --identifier "com.thlim.hangyeol.staged-update" \
    --scripts "$SCRIPTS_DIR" \
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
if ! /usr/bin/grep -Fq 'install-location="/"' \
    "$EXPANDED_DIR/PackageInfo"; then
    echo "Package has an unexpected installation location." >&2
    exit 1
fi
if [ -e "$EXPANDED_DIR/Scripts/preinstall" ] \
    || ! /usr/bin/cmp -s "$EXPANDED_DIR/Scripts/postinstall" Packaging/scripts/postinstall_session; then
    echo "Local package contains an unexpected session activation script." >&2
    exit 1
fi
if /usr/bin/grep -Fq '/Library/Input Methods/' \
    <<< "$PAYLOAD_FILES"; then
    echo "Package would change a registered input method during login." >&2
    exit 1
fi
if /usr/bin/lsbom -p u "$EXPANDED_DIR/Bom" \
    | /usr/bin/grep -vqx '0'; then
    echo "Staged update files must be installed as root." >&2
    exit 1
fi
EXPANDED_UPDATER="$EXPANDED_DIR/Payload/Library/Application Support/Hangyeol/Updater"
codesign --verify --strict --verbose=2 "$EXPANDED_UPDATER/HangyeolInstallerHelper"
EXPANDED_ARCHIVE="$EXPANDED_UPDATER/pending-app.tar.gz"
EXPANDED_HASH=$(/usr/bin/awk 'NR == 1 { print $1 }' \
    "$EXPANDED_UPDATER/pending-app.sha256")
ACTUAL_HASH=$(/usr/bin/shasum -a 256 "$EXPANDED_ARCHIVE" \
    | /usr/bin/awk '{ print $1 }')
if [ "$EXPANDED_HASH" != "$ACTUAL_HASH" ]; then
    echo "Packaged staged app checksum is invalid." >&2
    exit 1
fi
EXPANDED_APP_DIR="$TEMP_DIR/Reconstructed"
mkdir -p "$EXPANDED_APP_DIR"
/usr/bin/tar -xzf "$EXPANDED_ARCHIVE" -C "$EXPANDED_APP_DIR"
EXPANDED_APP="$EXPANDED_APP_DIR/$APP_NAME.app"
codesign --verify --strict --verbose=2 "$EXPANDED_APP"
/usr/bin/plutil -lint \
    "$EXPANDED_DIR/Payload/Library/LaunchDaemons/com.thlim.hangyeol.apply-staged-update.plist"
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
