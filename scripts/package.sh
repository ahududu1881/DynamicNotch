#!/bin/zsh
# Builds the app and wraps it in a drag-to-Applications disk image for a GitHub release:
# build/DynamicNotch-<version>.dmg (the app next to a shortcut to /Applications).
set -euo pipefail
cd "$(dirname "$0")/.."

# Releases are ad-hoc signed unless you pass a Developer ID: a developer certificate embeds its owner's name and
# email in the signature, and a public download should not carry that.
SIGN_IDENTITY="${SIGN_IDENTITY:--}" ./scripts/build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
DMG="build/DynamicNotch-$VERSION.dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

# ditto keeps the bundle intact; --norsrc/--noextattr stop AppleDouble "._" files from leaking into the image.
ditto --norsrc --noextattr --noqtn "build/Dynamic Notch.app" "$STAGING/Dynamic Notch.app"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Dynamic Notch $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
echo "Packaged $DMG"
