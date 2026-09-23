#!/bin/bash
# Runs as root until there is no desktop session or Hangyeol process.

set -euo pipefail
umask 022

UPDATER_DIR="/Library/Application Support/Hangyeol/Updater"
ARCHIVE="$UPDATER_DIR/pending-app.tar.gz"
HASH_FILE="$UPDATER_DIR/pending-app.sha256"
APP_PATH="/Library/Input Methods/Hangyeol.app"

if [ "$(/usr/bin/id -u)" != 0 ]; then
    echo "Hangyeol staged update requires root." >&2
    exit 1
fi
if [ ! -f "$ARCHIVE" ] || [ ! -f "$HASH_FILE" ]; then
    exit 0
fi

# A RunAtLoad daemon can start after an automatic login. Keep it armed until
# logout rather than dropping the only update attempt for this boot.
safe_to_update() {
    local console_user
    console_user=$(/usr/bin/stat -f '%Su' /dev/console 2>/dev/null || true)
    case "$console_user" in
        root|loginwindow)
            ! /usr/bin/pgrep -x Hangyeol >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

wait_for_inactive_session() {
    local announced=false
    while true; do
        if safe_to_update; then
            # Ignore a brief loginwindow interval while automatic login begins.
            /bin/sleep 2
            if safe_to_update; then
                return 0
            fi
        fi
        if [ "$announced" = false ]; then
            echo "Hangyeol update waiting for logout and input-method exit."
            announced=true
        fi
        /bin/sleep 1
    done
}

for trusted_file in "$ARCHIVE" "$HASH_FILE"; do
    if [ "$(/usr/bin/stat -f '%u' "$trusted_file")" != 0 ]; then
        echo "Hangyeol staged update file is not root-owned." >&2
        exit 1
    fi
done
EXPECTED_HASH=$(/usr/bin/awk 'NR == 1 { print $1 }' "$HASH_FILE")
ACTUAL_HASH=$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{ print $1 }')
if [ "${#EXPECTED_HASH}" != 64 ] || [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
    echo "Hangyeol staged app checksum is invalid." >&2
    exit 1
fi

WORK_DIR=""
PREVIOUS=""
cleanup() {
    if [ -n "$PREVIOUS" ] && [ -d "$PREVIOUS" ]; then
        if [ ! -d "$APP_PATH" ] \
            || ! /usr/bin/codesign --verify --strict "$APP_PATH"; then
            /bin/rm -rf "$APP_PATH"
            /bin/mv "$PREVIOUS" "$APP_PATH"
        fi
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        /bin/rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
while true; do
    wait_for_inactive_session
    WORK_DIR=$(/usr/bin/mktemp -d "/Library/Input Methods/.hangyeol-update.XXXXXX")
    PREVIOUS="$WORK_DIR/previous.app"
    /usr/bin/tar -xzf "$ARCHIVE" -C "$WORK_DIR"
    CANDIDATE="$WORK_DIR/Hangyeol.app"
    if [ ! -d "$CANDIDATE" ] \
        || ! /usr/bin/codesign --verify --strict "$CANDIDATE" \
        || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$CANDIDATE/Contents/Info.plist" 2>/dev/null || true)" \
            != "com.thlim.inputmethod.Hangyeol" ]; then
        echo "Hangyeol staged app identity or signature is invalid." >&2
        exit 1
    fi

    # A login may begin while the signed archive is unpacked. In that case,
    # discard the candidate and wait for the next inactive session.
    if ! safe_to_update; then
        echo "Hangyeol update waiting: login began during validation."
        cleanup
        WORK_DIR=""
        PREVIOUS=""
        continue
    fi

    if [ -d "$APP_PATH" ] \
        && /usr/bin/cmp -s "$APP_PATH/Contents/Info.plist" \
            "$CANDIDATE/Contents/Info.plist" \
        && /usr/bin/codesign --verify --strict "$APP_PATH"; then
        echo "Hangyeol staged version is already installed."
        break
    fi

    if [ -e "$APP_PATH" ]; then
        /bin/mv "$APP_PATH" "$PREVIOUS"
    fi
    if ! /bin/mv "$CANDIDATE" "$APP_PATH" \
        || ! /usr/bin/codesign --verify --strict "$APP_PATH"; then
        /bin/rm -rf "$APP_PATH"
        if [ -d "$PREVIOUS" ]; then
            /bin/mv "$PREVIOUS" "$APP_PATH"
        fi
        echo "Hangyeol inactive-session replacement failed; previous app restored." >&2
        exit 1
    fi
    echo "Hangyeol staged app installed outside the login session."
    break
done

# Remove the trigger so later boots do not unpack an already installed app.
/bin/rm -f "$ARCHIVE" "$HASH_FILE"
