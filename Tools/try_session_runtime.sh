#!/bin/bash
# Applies a locally built Hangyeol to the current login session the same way
# postinstall_session does, without building or installing a package.
# The canonical bundle in /Library/Input Methods is never modified.
#
# Usage: Tools/try_session_runtime.sh [--version <short-version> --build <build>]
set -euo pipefail
export COPYFILE_DISABLE=1

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=""
BUILD=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION=$2; shift 2 ;;
        --build) BUILD=$2; shift 2 ;;
        *) echo "usage: $0 [--version <short-version> --build <build>]" >&2; exit 64 ;;
    esac
done

cd "$REPO_ROOT"
swift build -c release --product Hangyeol
swift build -c release --product HangyeolInstallerHelper
HELPER="$REPO_ROOT/.build/release/HangyeolInstallerHelper"

SESSION_DIR=$(/usr/bin/mktemp -d /private/tmp/hangyeol-session.XXXXXX)
/bin/chmod 755 "$SESSION_DIR"
APP="$SESSION_DIR/Hangyeol.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Hangyeol "$APP/Contents/MacOS/Hangyeol"
cp Info.plist "$APP/Contents/"
cp -R Resources/. "$APP/Contents/Resources/"
cp AppIcon.icns icon.tiff input-ko.tiff "$APP/Contents/Resources/"
cp -R .build/release/Hangyeol_HangyeolCore.bundle "$APP/Contents/Resources/"
if [ -n "$VERSION" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$BUILD" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
find "$APP" -name '._*' -delete
xattr -cr "$APP" 2>/dev/null || true

SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
    | /usr/bin/awk -F'"' '/Apple Development:/{ print $2; exit }')
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "Apple Development signing identity not found." >&2
    exit 1
fi
codesign --force --options runtime --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict "$APP"

SESSION_ID=$("$HELPER" --session-id)
/usr/bin/printf '{"userID":%s,"sessionID":%s}\n' "$(id -u)" "$SESSION_ID" \
    > "$SESSION_DIR/session.json"

echo "candidate=$APP"
"$HELPER" --activate-session-runtime "$APP"
