#!/bin/sh
set -eu
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"

# retire the earlier LidAwake build
pkill -f "LidAwake.app/Contents/MacOS/LidAwake" 2>/dev/null || true
rm -rf "$DEST/LidAwake.app"
# ...and the build that was called RemoteAccess
pkill -f "RemoteAccess.app/Contents/MacOS/RemoteAccess" 2>/dev/null || true
rm -rf "$DEST/RemoteAccess.app"
launchctl bootout "gui/$(id -u)/com.rakesh717.remoteaccess" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.rakesh717.remoteaccess.plist"

rm -rf "$DEST/Tailgate.app"
cp -R build/Tailgate.app "$DEST/"

pkill -f "Tailgate.app/Contents/MacOS/Tailgate" 2>/dev/null || true
sleep 1
open "$DEST/Tailgate.app"
echo "installed: $DEST/Tailgate.app"

echo
./doctor.sh || echo "run ./doctor.sh --fix to resolve the items above"
