#!/bin/zsh
# Signs with Developer ID, notarizes, staples and zips the Mac app for direct download.
# One-time setup:  xcrun notarytool store-credentials couchpad --apple-id you@example.com --team-id TEAMID
# Then:            SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
set -e
cd "$(dirname "$0")"
: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your 'Developer ID Application: …' identity}"
./build.sh
APP="build/Couchpad.app"
ZIP="build/Couchpad-mac.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile couchpad --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Ready to upload: $PWD/$ZIP"
