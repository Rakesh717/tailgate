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
FAILS=0; WARNS=0
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$1"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$1"; WARNS=$((WARNS+1)); }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$1"; FAILS=$((FAILS+1)); }
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
  case "$STATE" in
    Running)
      ok "logged in and connected"
      ;;
    NeedsLogin|NoState|"")
      [ -n "$STATE" ] && bad "not logged in ($STATE)"
      if ask "start login now?"; then
        # --timeout keeps `up` from hanging forever; it prints/opens the auth URL.
        "$TS" up --timeout=120s || true
        STATE=$(ts_state)
        [ "$STATE" = Running ] && ok "logged in and connected" || bad "still not connected ($STATE)"
      else
        [ -n "$STATE" ] && hint "tailscale up   (or sign in from the menu bar icon)"
      fi
      ;;
    Stopped)
      bad "logged in but turned off"
      if ask "run tailscale up?"; then
        "$TS" up --timeout=60s || true
        [ "$(ts_state)" = Running ] && ok "connected" || bad "still stopped"
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

  t3_running() { ps -axo command= | grep -qF "$T3_APP/Contents/MacOS/"; }
  if t3_running; then
    ok "app running"
  else
    warn "app not running"
    if ask "launch T3 Code?"; then
      open "$T3_APP"; wait_for 20 t3_running && ok "launched" || bad "failed to launch"
    else
      hint "open \"$T3_APP\""
    fi
  fi

  # The server records its pid/port here once it is up.
  RT="$T3_HOME/userdata/server-runtime.json"
  if [ -f "$RT" ]; then
    PID=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$RT")
    PORT=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$RT")
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null && nc -z 127.0.0.1 "${PORT:-0}" 2>/dev/null; then
      ok "server listening on 127.0.0.1:$PORT"
      T3_PORT=$PORT
    else
      warn "server not running (stale $RT)"
      hint "start the T3 Code app; it starts the server"
    fi
  else
    warn "server has never run (no $RT)"
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

  # Is the T3 server reachable from the tailnet?
  if [ -n "$TS" ] && [ "$(ts_state)" = Running ] && [ -n "${T3_PORT:-}" ]; then
    if "$TS" serve status 2>/dev/null | grep -q ":$T3_PORT"; then
      ok "exposed to your tailnet via Tailscale Serve"
    else
      warn "T3 is only on localhost; phones/tablets on your tailnet can't reach it"
      hint "enable the Tailscale option in T3 Code settings, or run:"
      hint "tailscale serve --bg $T3_PORT"
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

# ─────────────────────────────────────────────────────────── Summary
printf '\n'
if [ "$FAILS" -gt 0 ]; then
  printf '%s%d problem(s)%s, %d warning(s).' "$R" "$FAILS" "$N" "$WARNS"
  [ "$FIX" -eq 0 ] && printf ' Run ./doctor.sh --fix to repair interactively.'
  printf '\n'; exit 1
elif [ "$WARNS" -gt 0 ]; then
  printf '%sAll good%s, %d warning(s).\n' "$Y" "$N" "$WARNS"
else
  printf '%sAll good.%s\n' "$G" "$N"
fi
