#!/bin/sh
# Installs (or updates) Tailgate from its latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/Rakesh717/tailgate/main/scripts/get.sh | sh
#
# Downloads the release zip, checks it against the release's SHA256SUMS and its
# code signature, puts Tailgate.app in /Applications (or ~/Applications), asks
# for your password once to install the sleep helper and the `tailgate`
# command, launches the app and runs `tailgate doctor`.
#
#   TAILGATE_VERSION=0.1.0   install that version instead of the latest
#   TAILGATE_DIR=~/Apps      install into this folder
#   TAILGATE_BASE_URL=...    download from here instead of GitHub (for testing)
#
# Everything runs from main(), so a download cut off halfway runs nothing.
set -eu

REPO="Rakesh717/tailgate"
BASE="${TAILGATE_BASE_URL:-https://github.com/$REPO/releases}"

say() { printf '%s\n' "$*"; }
die() { printf 'tailgate install: %s\n' "$*" >&2; exit 1; }

main() {
  [ "$(uname -s)" = Darwin ] || die "Tailgate is a macOS app."
  major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 13 ] || die "Tailgate needs macOS 13 or later."

  # Latest version: GitHub redirects /latest to /tag/v<version>.
  version="${TAILGATE_VERSION:-}"
  if [ -z "$version" ]; then
    tag_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$BASE/latest") \
      || die "couldn't reach $BASE (offline, or no release published yet)."
    version=${tag_url##*/v}
    case "$version" in
      ''|*/*) die "no release found at $BASE." ;;
    esac
  fi
  say "Installing Tailgate ${version}…"

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT INT TERM
  zip="Tailgate-$version.zip"
  curl -fsSL -o "$work/$zip" "$BASE/download/v$version/$zip" || die "download failed: $zip"
  curl -fsSL -o "$work/SHA256SUMS" "$BASE/download/v$version/SHA256SUMS" || die "download failed: SHA256SUMS"

  expected=$(awk -v f="$zip" '$2 == f || $2 == "*"f { print $1 }' "$work/SHA256SUMS")
  actual=$(shasum -a 256 "$work/$zip" | awk '{ print $1 }')
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "checksum mismatch; not installing."

  ditto -x -k "$work/$zip" "$work/unpacked"
  new="$work/unpacked/Tailgate.app"
  [ "$(defaults read "$new/Contents/Info" CFBundleIdentifier 2>/dev/null)" = com.rakesh717.tailgate ] \
    || die "the download isn't Tailgate; not installing."
  codesign --verify --strict "$new" 2>/dev/null || die "the app's code signature is invalid; not installing."

  # Where: TAILGATE_DIR, else where it's already installed, else /Applications
  # when writable, else ~/Applications.
  if [ -n "${TAILGATE_DIR:-}" ]; then
    dir=$TAILGATE_DIR
  elif [ -d /Applications/Tailgate.app ]; then
    dir=/Applications
  elif [ -d "$HOME/Applications/Tailgate.app" ]; then
    dir="$HOME/Applications"
  elif [ -w /Applications ]; then
    dir=/Applications
  else
    dir="$HOME/Applications"
  fi
  mkdir -p "$dir"
  app="$dir/Tailgate.app"

  # An installed copy quits through its own CLI, so Remote access turns off cleanly.
  if [ -x "$app/Contents/Resources/tailgate" ] && pgrep -f "$app/Contents/MacOS/Tailgate" >/dev/null 2>&1; then
    "$app/Contents/Resources/tailgate" quit >/dev/null 2>&1 || true
  fi
  rm -rf "$app"
  mv "$new" "$app"
  # curl doesn't quarantine, but a copy that came from a browser before might.
  xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
  say "Installed $app"

  # Sleep helper + `tailgate` command: root-owned, so one password prompt.
  # sudo asks on the terminal even when this script arrives through a pipe.
  if (: </dev/tty) 2>/dev/null; then
    say "Installing the sleep helper and the tailgate command (asks for your password):"
    if sudo /bin/sh "$app/Contents/Resources/install-helper.sh" "$app" "$(id -un)" >/dev/null </dev/tty; then
      say "Installed /usr/local/bin/tailgate"
    else
      say "Skipped; Tailgate asks for it the first time you turn on Remote access."
    fi
  else
    say "No terminal to ask for a password: Tailgate installs its helper the first time you turn on Remote access."
  fi

  env -u ELECTRON_RUN_AS_NODE open "$app"

  say ""
  "$app/Contents/Resources/tailgate" doctor || true
  say ""
  say "Tailgate is in your menu bar. Turn on Remote access there, or run: tailgate on"
}

main "$@"
