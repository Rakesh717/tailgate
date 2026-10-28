#!/bin/sh
set -eu
cd "$(dirname "$0")"

./build.sh

DEST="$HOME/Applications"
mkdir -p "$DEST"

rm -rf "$DEST/Tailgate.app"
# Move, not copy: a second Tailgate.app left in build/ shows up in Spotlight.
mv build/Tailgate.app "$DEST/"

pkill -f "Tailgate.app/Contents/MacOS/Tailgate" 2>/dev/null || true
sleep 1
# Don't pass a VS Code terminal's ELECTRON_RUN_AS_NODE on to the app (and from
# there to T3 Code, which won't start with it).
env -u ELECTRON_RUN_AS_NODE open "$DEST/Tailgate.app"
echo "installed: $DEST/Tailgate.app"

# Sleep helper + the `tailgate` command (root-owned, so one password prompt).
# The app does the same on its first toggle if this is skipped.
APP_CLI="$DEST/Tailgate.app/Contents/Resources/tailgate"
if [ "$(readlink /usr/local/bin/tailgate 2>/dev/null)" = "$APP_CLI" ] && [ -x /usr/local/libexec/tailgate-helper ]; then
  echo "command: /usr/local/bin/tailgate"
elif [ -t 0 ]; then
  echo "installing the sleep helper and the tailgate command (asks for your password):"
  sudo /bin/sh "$DEST/Tailgate.app/Contents/Resources/install-helper.sh" "$DEST/Tailgate.app" "$(id -un)" >/dev/null \
    && echo "command: /usr/local/bin/tailgate"
else
  echo "to install the tailgate command: sudo sh \"$DEST/Tailgate.app/Contents/Resources/install-helper.sh\""
fi

echo
./doctor.sh || echo "run ./doctor.sh --fix to resolve the items above"
