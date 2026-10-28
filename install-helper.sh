#!/bin/sh
# Installs the root-side helper and a narrow sudoers rule so the menu bar app
# can toggle lid sleep without prompting every time.
# Safe to re-run.
set -eu
USER_NAME="${SUDO_USER:-$(id -un)}"

# retire the helper from when this app was called RemoteAccess
rm -f /usr/local/sbin/remote-access /etc/sudoers.d/remote-access

install -d -o root -g wheel -m 0755 /usr/local/sbin

cat > /usr/local/sbin/tailgate <<'HELPER'
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
  *) echo "usage: tailgate on|off|status" >&2; exit 64 ;;
esac
HELPER

chown root:wheel /usr/local/sbin/tailgate
chmod 0755 /usr/local/sbin/tailgate

TMP="$(mktemp /tmp/tailgate.sudoers.XXXXXX)"
printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/tailgate on, /usr/local/sbin/tailgate off, /usr/local/sbin/tailgate status\n' "$USER_NAME" > "$TMP"
chown root:wheel "$TMP"
chmod 0440 "$TMP"
/usr/sbin/visudo -cf "$TMP" >/dev/null
mv "$TMP" /etc/sudoers.d/tailgate
echo ok
