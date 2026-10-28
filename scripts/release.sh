#!/bin/sh
# Produces dist/Tailgate-<version>.dmg (+ .zip and SHA-256 sums).
#
#   ./scripts/release.sh                      ad-hoc signed: works, but Gatekeeper warns
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=tailgate ./scripts/release.sh   signed + notarized + stapled
#
# One-time notary setup:
#   xcrun notarytool store-credentials tailgate --apple-id you@example.com --team-id TEAMID
set -eu
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
OUT="dist"
DMG="$OUT/Tailgate-$VERSION.dmg"
ZIP="$OUT/Tailgate-$VERSION.zip"

rm -rf "$OUT"; mkdir -p "$OUT"
./build.sh

# --- DMG: app + /Applications shortcut
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R build/Tailgate.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Tailgate $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

# --- Notarize + staple
if [ -n "${NOTARY_PROFILE:-}" ]; then
    [ -n "${SIGN_IDENTITY:-}" ] || { echo "notarization needs SIGN_IDENTITY" >&2; exit 1; }
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature -v "$DMG"
else
    echo "note: not notarized. Users must right-click → Open the first time." >&2
fi

# --- zip (for Homebrew) and checksums
ditto -c -k --keepParent build/Tailgate.app "$ZIP"
( cd "$OUT" && shasum -a 256 "Tailgate-$VERSION.dmg" "Tailgate-$VERSION.zip" > SHA256SUMS )

echo
cat "$OUT/SHA256SUMS"
echo
echo "release artifacts in $OUT/"
