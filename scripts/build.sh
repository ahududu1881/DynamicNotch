#!/bin/zsh
# Builds "build/Dynamic Notch.app" (release) and signs it.
#
# Signing: set SIGN_IDENTITY to a certificate name to pick one; otherwise the first Apple Development /
# Developer ID Application identity in your keychain is used, and without one the app is ad-hoc signed.
# A stable identity keeps the Accessibility and Full Disk Access permissions across rebuilds;
# an ad-hoc signature makes macOS ask for them again after every build.
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Dynamic Notch"
EXECUTABLE="DynamicNotch"
APP="build/$NAME.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXECUTABLE"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lang in en tr; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Resources/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/"
done
# Example plugins the settings window can copy into the user's plugin folder.
mkdir -p "$APP/Contents/Resources/examples"
cp -R Plugins/examples/. "$APP/Contents/Resources/examples/"

# MediaRemote bridge: the dylib is loaded into /usr/bin/perl, so it needs an arm64e slice.
clang -arch arm64e -arch x86_64 -dynamiclib -fobjc-arc -framework Foundation \
    -o "$APP/Contents/Resources/libDynamicNotchMR.dylib" Helper/MediaRemoteBridge.m
cp Helper/stream.pl "$APP/Contents/Resources/stream.pl"

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -E 'Apple Development|Developer ID Application' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
codesign --force --sign "${IDENTITY:--}" "$APP/Contents/Resources/libDynamicNotchMR.dylib"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"
