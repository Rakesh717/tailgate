# Changelog

## 1.0.0
- Menu bar app: keeps the Mac awake with the lid closed, makes sure Tailscale is
  connected and T3 Code is running, and shares T3 Code on the tailnet with a QR code.
- Requirement rows for Tailscale and T3 Code (installed, running, signed in) and a
  `doctor.sh` health check with `--fix`.
- Universal binary (Apple silicon + Intel), hardened runtime, DMG release script.
