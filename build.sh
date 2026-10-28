#!/bin/sh
# Builds build/Tailgate.app (universal: arm64 + x86_64).
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" ./build.sh   # real signing
# Without SIGN_IDENTITY the app is ad-hoc signed (fine locally, not distributable).
set -eu
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
BUILD="${BUILD_NUMBER:-1}"
APP="build/Tailgate.app"
BIN="$APP/Contents/MacOS/Tailgate"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library \
        -target "$arch-apple-macos13.0" \
        -framework SwiftUI -framework AppKit -framework CoreImage \
        Sources/main.swift \
        -o "build/obj/Tailgate-$arch"
done
lipo -create build/obj/Tailgate-arm64 build/obj/Tailgate-x86_64 -output "$BIN"

cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp doctor.sh install-helper.sh bin/tailgate Resources/AppIcon.icns "$APP/Contents/Resources/"

IDENTITY="${SIGN_IDENTITY:--}"
if [ "$IDENTITY" = - ]; then
    TS="--timestamp=none"
else
    TS="--timestamp"
fi
codesign --force "$TS" --options runtime --entitlements Tailgate.entitlements \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "built $APP ($VERSION, $(lipo -archs "$BIN"), signed: $([ "$IDENTITY" = - ] && echo ad-hoc || echo "$IDENTITY"))"
