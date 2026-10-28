#!/bin/sh
# Checks that everything Tailgate exists to serve is installed and signed in:
#   Tailscale  – installed, daemon running, logged in, key not expiring
#   T3 Code    – installed, server up, signed in, a provider logged in
#   Tailgate   – root helper + sudoers rule present
#
#   ./doctor.sh          report only (exit 1 if anything is broken)
#   ./doctor.sh --fix    offer to install / log in / start what is missing
#   ./doctor.sh --yes    with --fix, answer yes to every prompt
set -u

FIX=0; YES=0
for a in "$@"; do
  case "$a" in
    --fix) FIX=1 ;;
    --yes|-y) FIX=1; YES=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 64 ;;
  esac
done

if [ -t 1 ]; then G=$(printf '\033[32m'); Y=$(printf '\033[33m'); R=$(printf '\033[31m'); D=$(printf '\033[2m'); N=$(printf '\033[0m'); else G=; Y=; R=; D=; N=; fi
FAILS=0; WARNS=0; FIXED=0
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; WARNS=$((WARNS+1)); }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS+1)); }
# After a repair attempt for a problem bad() already counted:
fixed() { ok "$1"; FAILS=$((FAILS-1)); FIXED=$((FIXED+1)); }
still() { printf '  %s✗%s %s\n' "$R" "$N" "$1"; }
hint() { printf '    %s%s%s\n' "$D" "$1" "$N"; }
head_() { printf '\n%s\n' "$1"; }

# ask "question" → 0 if the user agreed (and --fix is on)
ask() {
  [ "$FIX" -eq 1 ] || return 1
  [ "$YES" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  printf '    → %s [y/N] ' "$1"; read -r reply
  case "$reply" in y|Y|yes) return 0 ;; *) return 1 ;; esac
}

wait_for() { # wait_for <seconds> <command...>
  n=$1; shift
  while [ "$n" -gt 0 ]; do "$@" >/dev/null 2>&1 && return 0; sleep 1; n=$((n-1)); done
  return 1
}

find_app() { # find_app <glob-ish name prefix>
  for d in /Applications "$HOME/Applications"; do
    for a in "$d"/"$1"*.app; do [ -d "$a" ] && { printf '%s' "$a"; return 0; }; done
  done
  return 1
}

plist_ver() { /usr/bin/defaults read "$1/Contents/Info" CFBundleShortVersionString 2>/dev/null; }

# ─────────────────────────────────────────────────────────── Tailscale
TS=""
find_ts() {
  TS=""
  for c in "$(command -v tailscale 2>/dev/null)" /usr/local/bin/tailscale /opt/homebrew/bin/tailscale \
           /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    [ -n "$c" ] && [ -x "$c" ] && { TS=$c; return 0; }
  done
  return 1
}
ts_state() { "$TS" status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -1; }
# With the Tailscale app quit, the state can still read "Running" while this
# Mac is offline, so "connected" needs the app up and Self.Online too.
ts_gui() { pgrep -f 'Tailscale\.app/Contents/MacOS/Tailscale$' >/dev/null 2>&1; }
ts_online() { [ "$("$TS" status --json 2>/dev/null | plutil -extract Self.Online raw -o - - 2>/dev/null)" = true ]; }
ts_up() { # ts_up <timeout>
  # `up` refuses to run unless every non-default setting (e.g. --accept-routes)
  # is repeated; it prints the exact command that keeps them, so run that.
  # Output streams through tee so a login URL shows up while `up` waits.
  log=$(mktemp)
  "$TS" up --timeout="$1" 2>&1 | tee "$log"
  args=$(sed -n '/requires mentioning all/,$ s/^[[:space:]]*tailscale up\(.*\)$/\1/p' "$log" | tail -1)
  rm -f "$log"
  [ -n "$args" ] || return 0
  hint "retrying with your current settings: tailscale up$args"
  eval "set -- $args"
  "$TS" up "$@"
}

head_ "Tailscale"
find_ts
TS_APP=$(find_app Tailscale || true)
if [ -z "$TS" ] && [ -z "$TS_APP" ]; then
  bad "not installed"
  if command -v brew >/dev/null 2>&1; then
    ask "brew install --cask tailscale-app?" && brew install --cask tailscale-app && find_ts
  else
    hint "install from https://tailscale.com/download/mac (Homebrew not found)"
  fi
  [ -z "$TS" ] && [ "$FAILS" -gt 0 ] && hint "brew install --cask tailscale-app"
fi

if [ -n "$TS_APP" ]; then ok "app: $TS_APP ($(plist_ver "$TS_APP"))"; fi
if [ -n "$TS" ]; then
  ok "cli: $TS ($("$TS" version 2>/dev/null | head -1))"
  STATE=$(ts_state)
  if [ -z "$STATE" ]; then
    bad "daemon not responding"
    if [ -n "$TS_APP" ] && ask "launch Tailscale.app?"; then
      open -a Tailscale; wait_for 20 sh -c "[ -n \"\$('$TS' status --json 2>/dev/null)\" ]"; STATE=$(ts_state)
    else
      hint "open -a Tailscale"
    fi
  fi
  if [ -n "$TS_APP" ] && ! ts_gui; then
    bad "app not running (this Mac is offline without it)"
    if ask "start Tailscale?"; then
      open -g -a Tailscale
      wait_for 20 ts_gui && fixed "started" && wait_for 20 ts_online
      STATE=$(ts_state)
    else
      hint "open -a Tailscale"
    fi
  fi
  # Its state means nothing while the app is closed; that was reported above.
  [ -n "$TS_APP" ] && ! ts_gui && STATE=AppClosed
  case "$STATE" in
    AppClosed) ;;
    Running)
      if ts_online; then
        ok "logged in and connected"
      else
        bad "logged in, but this Mac is offline"
        hint "open the Tailscale menu and check it says Connected"
      fi
      ;;
    NeedsLogin|NoState|"")
      [ -n "$STATE" ] && bad "not logged in ($STATE)"
      if ask "start login now?"; then
        # --timeout keeps `up` from hanging forever; it prints/opens the auth URL.
        ts_up 120s || true
        STATE=$(ts_state)
        if [ "$STATE" = Running ]; then fixed "logged in and connected"; else still "still not connected ($STATE)"; fi
      else
        [ -n "$STATE" ] && hint "tailscale up   (or sign in from the menu bar icon)"
      fi
      ;;
    Stopped)
      bad "logged in but turned off"
      if ask "run tailscale up?"; then
        ts_up 60s || true
        if [ "$(ts_state)" = Running ]; then fixed "connected"; else still "still stopped"; fi
      else
        hint "tailscale up"
      fi
      ;;
    NeedsMachineAuth)
      bad "waiting for an admin to approve this device"
      hint "https://login.tailscale.com/admin/machines"
      ;;
    *) warn "state: $STATE" ;;
  esac

  if [ "$(ts_state)" = Running ]; then
    JSON=$("$TS" status --json 2>/dev/null)
    NAME=$(printf '%s' "$JSON" | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -1)
    IP=$("$TS" ip -4 2>/dev/null | head -1)
    [ -n "$NAME" ] && ok "reachable as $NAME${IP:+ ($IP)}"
    EXP=$(printf '%s' "$JSON" | sed -n 's/.*"KeyExpiry": *"\([0-9-]*\)T.*/\1/p' | head -1)
    if [ -n "$EXP" ]; then
      NOW=$(date +%s); EXPS=$(date -j -f %Y-%m-%d "$EXP" +%s 2>/dev/null || echo 0)
      DAYS=$(( (EXPS - NOW) / 86400 ))
      if [ "$EXPS" -gt 0 ] && [ "$DAYS" -lt 14 ]; then
        warn "node key expires $EXP ($DAYS days) – a closed-lid Mac can't re-auth itself"
        hint "disable key expiry for this device in the admin console"
      else
        ok "node key valid until $EXP"
      fi
    fi
    if "$TS" status 2>&1 | grep -qi 'health check'; then
      warn "tailscale reports health warnings: run 'tailscale status' to read them"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────── T3 Code
head_ "T3 Code"
T3_APP=$(find_app "T3 Code" || true)
T3_HOME="${T3CODE_HOME:-$HOME/.t3}"
T3_BIN="$T3_HOME/bin/t3"
if [ -z "$T3_APP" ]; then
  bad "not installed"
  if command -v brew >/dev/null 2>&1; then
    if ask "brew install --cask t3-code?"; then
      brew install --cask t3-code && T3_APP=$(find_app "T3 Code" || true)
    else
      hint "brew install --cask t3-code"
    fi
  else
    hint "download from https://t3.codes"
  fi
fi

if [ -n "$T3_APP" ]; then
  ok "app: $T3_APP ($(plist_ver "$T3_APP"))"

  # Match the executable path exactly: grepping full command lines also
  # matches this grep, whose own arguments contain the path.
  T3_EXE="$T3_APP/Contents/MacOS/$(basename "$T3_APP" .app)"
  t3_running() { ps -axo comm= | grep -qxF "$T3_EXE"; }
  t3_stopped() { ! t3_running; }
  # The server writes its pid/port here while it runs and removes it on exit.
  RT="$T3_HOME/userdata/server-runtime.json"
  t3_server() {
    [ -f "$RT" ] || return 1
    PID=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$RT")
    PORT=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$RT")
    [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && nc -z 127.0.0.1 "${PORT:-0}" 2>/dev/null
  }
  # `open` hands this shell's environment to the app, and an inherited
  # ELECTRON_RUN_AS_NODE (e.g. from a VS Code terminal) makes it exit at once.
  t3_start() { env -u ELECTRON_RUN_AS_NODE open -g "$T3_APP" && wait_for 45 t3_server; }

  if t3_server; then
    ok "server listening on 127.0.0.1:$PORT"
    T3_PORT=$PORT
  elif t3_running; then
    bad "app is open but its server isn't running"
    if ask "restart T3 Code?"; then
      osascript -e "quit app \"$T3_APP\"" >/dev/null 2>&1
      wait_for 15 t3_stopped
      if t3_start; then fixed "restarted, server on 127.0.0.1:$PORT"; T3_PORT=$PORT; else still "server still not running"; fi
    else
      hint "quit T3 Code and open it again"
    fi
  else
    bad "not running"
    if ask "start T3 Code?"; then
      if t3_start; then fixed "started, server on 127.0.0.1:$PORT"; T3_PORT=$PORT; else still "server did not start"; fi
    else
      hint "open \"$T3_APP\""
    fi
  fi

  # Account sign-in
  if [ -s "$T3_HOME/userdata/clerk-tokens.json" ]; then
    ok "signed in to T3 Code"
  else
    bad "not signed in to T3 Code"
    hint "open the app and sign in"
  fi

  # An agent provider must be logged in or T3 has nothing to drive.
  PROV=0
  if command -v claude >/dev/null 2>&1; then
    if claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then
      ok "provider: Claude Code logged in"; PROV=$((PROV+1))
    else
      warn "Claude Code installed but not logged in"
      if ask "run 'claude auth login'?"; then claude auth login && PROV=$((PROV+1)); else hint "claude auth login"; fi
    fi
  fi
  if command -v codex >/dev/null 2>&1; then
    if codex login status >/dev/null 2>&1; then
      ok "provider: Codex logged in"; PROV=$((PROV+1))
    else
      warn "Codex installed but not logged in"
      if ask "run 'codex login'?"; then codex login && PROV=$((PROV+1)); else hint "codex login"; fi
    fi
  fi
  if command -v opencode >/dev/null 2>&1; then
    ok "provider: OpenCode installed"; PROV=$((PROV+1))
  fi
  if [ "$PROV" -eq 0 ]; then
    bad "no agent provider available (install and log in to Claude Code, Codex or OpenCode)"
  fi

  # Tailgate mints device pairing links through the CLI bundled in the app.
  if [ -n "${T3_PORT:-}" ]; then
    T3_CLI="$T3_APP/Contents/Resources/app.asar/apps/server/dist/bin.mjs"
    if ELECTRON_RUN_AS_NODE=1 T3CODE_HOME="$T3_HOME" "$T3_EXE" "$T3_CLI" auth pairing list --json >/dev/null 2>&1; then
      ok "device pairing available"
    else
      bad "can't create pairing links (T3 Code CLI failed)"
      hint "ELECTRON_RUN_AS_NODE=1 \"$T3_EXE\" \"$T3_CLI\" auth pairing list"
    fi
  fi

  # Sharing is Tailgate's job; this only reports it.
  if [ -n "$TS" ] && [ "$(ts_state)" = Running ] && [ -n "${T3_PORT:-}" ]; then
    if "$TS" serve status 2>/dev/null | grep -q ":$T3_PORT"; then
      ok "shared on your tailnet"
    else
      hint "not shared on your tailnet yet: turn on Remote access in Tailgate"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────── Tailgate
head_ "Tailgate"
HELPER=/usr/local/sbin/tailgate
if [ -x "$HELPER" ] && [ -f /etc/sudoers.d/tailgate ]; then
  ok "root helper and sudoers rule installed"
  HOUT=$(sudo -n "$HELPER" status 2>&1)
  REAL=off; pmset -g | grep -q 'SleepDisabled[[:space:]]*1' && REAL=on
  if [ "$HOUT" = "$REAL" ]; then
    ok "passwordless toggle works (lid sleep currently: $HOUT)"
  elif [ "$HOUT" = on ] || [ "$HOUT" = off ]; then
    bad "helper reports '$HOUT' but pmset says '$REAL' (outdated helper)"
    if ask "reinstall helper (needs sudo)?"; then
      sudo /bin/sh "$(dirname "$0")/install-helper.sh" && ok "reinstalled" || bad "reinstall failed"
    else
      hint "sudo /bin/sh ./install-helper.sh"
    fi
  else
    bad "helper failed: $HOUT"
    hint "re-run: sudo /bin/sh $(dirname "$0")/install-helper.sh"
  fi
else
  warn "helper not installed yet (the app installs it on first toggle)"
  if ask "install it now (needs sudo)?"; then
    sudo /bin/sh "$(dirname "$0")/install-helper.sh" && ok "installed" || bad "install failed"
  else
    hint "sudo /bin/sh ./install-helper.sh"
  fi
fi
if [ -d "$HOME/Applications/Tailgate.app" ]; then ok "app: ~/Applications/Tailgate.app"; else warn "app not installed: run ./install.sh"; fi

# Let a running Tailgate show the new state now instead of on its next check.
pgrep -x Tailgate >/dev/null 2>&1 && open -g "tailgate://refresh" >/dev/null 2>&1

# ─────────────────────────────────────────────────────────── Summary
printf '\n'
[ "$FIXED" -gt 0 ] && printf '%sFixed %d problem(s).%s\n' "$G" "$FIXED" "$N"
if [ "$FAILS" -gt 0 ]; then
  printf '%s%d problem(s)%s, %d warning(s).' "$R" "$FAILS" "$N" "$WARNS"
  [ "$FIX" -eq 0 ] && printf ' Run ./doctor.sh --fix to repair interactively.'
  printf '\n'; exit 1
elif [ "$WARNS" -gt 0 ]; then
  printf '%sAll good%s, %d warning(s).\n' "$Y" "$N" "$WARNS"
else
  printf '%sAll good.%s\n' "$G" "$N"
fi
