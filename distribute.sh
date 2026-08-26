#!/bin/bash
set -e

# Configuration
APP_NAME="Hangyeol"
APP_BUNDLE="${APP_NAME}.app"
ZIP_NAME="${APP_NAME}.zip"
SIGNING_IDENTITY="Developer ID Application: Chanwoo Park (M4U438VG59)"
TEAM_ID="M4U438VG59" # Extracted from cert

# Credentials (Set these securely in env, or script will prompt)
# KEYCHAIN_PROFILE="HangyeolNotary"

echo "==== 1. Clean & Build ===="
./install.sh # This builds and installs Hangyeol locally first.
# Let's extract build logic or just use swift build
swift build -c release -Xswiftc -DNDEBUG
mkdir -p build_dist/Contents/MacOS
mkdir -p build_dist/Contents/Resources
cp .build/release/Hangyeol build_dist/Contents/MacOS/Hangyeol
cp Info.plist build_dist/Contents/
cp -R Resources/* build_dist/Contents/Resources/ || true
cp "AppIcon.icns" build_dist/Contents/Resources/ 2>/dev/null || true
cp "icon.tiff" build_dist/Contents/Resources/ 2>/dev/null || true
cp "input-ko.tiff" build_dist/Contents/Resources/ 2>/dev/null || true

# Copy Swift Package Manager resource bundle (required for Bundle.module / L10n)
if [ -d ".build/release/Hangyeol_HangyeolCore.bundle" ]; then
    cp -R ".build/release/Hangyeol_HangyeolCore.bundle" build_dist/Contents/Resources/
    echo "Copied Hangyeol_HangyeolCore.bundle"
else
    echo "Warning: Hangyeol_HangyeolCore.bundle not found"
fi


# Rename to .app
rm -rf "$APP_BUNDLE"
mv build_dist "$APP_BUNDLE"

echo "==== 2. Code Signing ===="
echo "Signing with $SIGNING_IDENTITY..."
codesign --force --options runtime --timestamp \
    --entitlements Hangyeol.entitlements \
    --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

echo "==== 3. Verifying Signature ===="
codesign -vv -d "$APP_BUNDLE"

echo "==== 4. Archiving for Notarization ===="
# Must use zip or dmg for notary service
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_NAME"
echo "Created $ZIP_NAME"

echo "==== 5. Notarization ===="
echo "To notarize, you need an App-Specific Password."
echo "1. Go to appleid.apple.com -> Sign-In and Security -> App-Specific Passwords -> Generate."
echo "2. Create a keychain profile (one-time setup):"
echo "   xcrun notarytool store-credentials \"HangyeolNotary\" --apple-id \"YOUR_EMAIL\" --team-id \"$TEAM_ID\" --password \"YOUR_APP_SPECIFIC_PASSWORD\""
echo "3. Run this script again with NOTARIZE=true"

if [ "$NOTARIZE" = "true" ]; then
    echo "Submitting to Apple Notary Service..."
    xcrun notarytool submit "$ZIP_NAME" --keychain-profile "HangyeolNotary" --wait
    
    echo "Stapling ticket..."
    xcrun stapler staple "$APP_BUNDLE"
    
    echo "Done! You can now verify standard Gatekeeper acceptance:"
    spctl --assess --type execute --verbose --ignore-cache "$APP_BUNDLE"
    
    # Re-zip stapled app
    ditto -c -k --keepParent "$APP_BUNDLE" "Hangyeol_Notarized.zip"
    echo "Final distribution file: Hangyeol_Notarized.zip"
fi
