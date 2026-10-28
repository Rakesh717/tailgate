# Changelog

## Unreleased
- The QR code is now a one-time T3 Code pairing link (expires after 10 minutes),
  so a new phone or tablet is signed in by scanning it. **Pair a device…** makes
  a new one; turning Remote access off or quitting revokes it.
- Remote access stays on when Tailscale or T3 Code drops, and Tailgate brings
  them back in the background instead of switching off with sleep still blocked.
- Tailscale and T3 Code are started in the background without taking focus;
  T3 Code's real port is read from its runtime file.
- `tailscale up` keeps existing settings such as `--accept-routes` instead of
  failing.
- On launch, a sleep block left behind by a killed earlier run is undone.
- `doctor.sh` checks that T3 Code's server is actually running (offering to
  restart the app when it is open without it) and that pairing links can be made.

## 1.0.0
- Menu bar app: keeps the Mac awake with the lid closed, makes sure Tailscale is
  connected and T3 Code is running, and shares T3 Code on the tailnet with a QR code.
- Requirement rows for Tailscale and T3 Code (installed, running, signed in) and a
  `doctor.sh` health check with `--fix`.
- Universal binary (Apple silicon + Intel), hardened runtime, DMG release script.
