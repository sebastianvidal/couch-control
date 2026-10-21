#!/bin/zsh
# Builds the Mac menu-bar app into Mac/build/Couch Control.app
set -e -o pipefail
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -v '^\[' || true
APP="build/Couch Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/CouchControlMac "$APP/Contents/MacOS/CouchControl"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with SIGN_IDENTITY (see release.sh) or, failing that, any Apple Development
# certificate in the keychain: a certificate gives the app a stable identity, so the
# Accessibility grant survives rebuilds. Ad-hoc signing is the last resort.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signed as: ${IDENTITY:-ad-hoc}"
echo "Built: $PWD/$APP"
