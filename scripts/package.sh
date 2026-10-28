#!/bin/zsh
# Builds the app and zips it for a GitHub release: build/DynamicNotch-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

# Releases are ad-hoc signed unless you pass a Developer ID: a developer certificate embeds its owner's name and
# email in the signature, and a public zip should not carry that.
SIGN_IDENTITY="${SIGN_IDENTITY:--}" ./scripts/build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/DynamicNotch-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "build/Dynamic Notch.app" "$ZIP"
echo "Packaged $ZIP"
