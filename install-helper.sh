#!/bin/sh
# Installs, as root (the app runs this behind its one admin prompt):
#   /usr/local/libexec/tailgate-helper  toggles lid sleep; a narrow sudoers rule
#                                       lets the app run it without a password
#   /usr/local/bin/tailgate             the command-line tool (a symlink into the app)
# Safe to re-run.
#
#   sudo sh install-helper.sh [/path/to/Tailgate.app] [user]
# The app defaults to the one this script sits in; the user to whoever ran sudo.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
case "$here" in
  */Contents/Resources) APP_DEFAULT=$(cd "$here/../.." && pwd) ;;
  *) APP_DEFAULT="" ;;
esac
APP="${1:-$APP_DEFAULT}"
USER_NAME="${2:-${SUDO_USER:-$(id -un)}}"
HELPER=/usr/local/libexec/tailgate-helper
CLI=/usr/local/bin/tailgate

# retire earlier helpers: RemoteAccess's, and /usr/local/sbin/tailgate, which
# shared its name with the command-line tool
rm -f /usr/local/sbin/remote-access /etc/sudoers.d/remote-access /usr/local/sbin/tailgate

install -d -o root -g wheel -m 0755 /usr/local/libexec
cat > "$HELPER" <<'HELPER'
#!/bin/sh
set -eu
case "${1:-}" in
  on)  exec /usr/bin/pmset -a disablesleep 1 ;;
  off) exec /usr/bin/pmset -a disablesleep 0 ;;
  status)
    if /usr/sbin/ioreg -n IOPMrootDomain -r -d 1 | /usr/bin/grep -q '"SleepDisabled" = Yes'; then
      echo on
    else
      echo off
    fi
    ;;
  *) echo "usage: tailgate-helper on|off|status" >&2; exit 64 ;;
esac
HELPER
chown root:wheel "$HELPER"
chmod 0755 "$HELPER"

TMP="$(mktemp /tmp/tailgate.sudoers.XXXXXX)"
printf '%s ALL=(root) NOPASSWD: %s on, %s off, %s status\n' "$USER_NAME" "$HELPER" "$HELPER" "$HELPER" > "$TMP"
chown root:wheel "$TMP"
chmod 0440 "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null
mv "$TMP" /etc/sudoers.d/tailgate

# The command-line tool. Never replace a file that isn't our symlink.
if [ -n "$APP" ] && [ -x "$APP/Contents/Resources/tailgate" ]; then
  install -d -o root -g wheel -m 0755 /usr/local/bin
  if [ -e "$CLI" ] && [ ! -L "$CLI" ]; then
    echo "note: $CLI exists and isn't a symlink; left it alone" >&2
  else
    ln -sfn "$APP/Contents/Resources/tailgate" "$CLI"
  fi
fi
echo ok
