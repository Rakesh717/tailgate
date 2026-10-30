# Changelog

## 0.1.1
- Remote access survives an internet outage. While the network is down,
  Tailgate keeps the lid awake and the share in place and shows "Waiting for
  Tailscale to reconnect…" until Tailscale comes back on its own. A restart
  that fails only because Tailscale can't connect yet is retried instead of
  turning Remote access off. A logout still turns it off.

## 0.1.0
First release.

**Menu bar app**
- **Remote access** keeps the Mac awake with the lid closed and shares T3 Code
  on your tailnet over HTTPS (plain HTTP on :8080 if the tailnet has no
  certificates). It picks a free tailnet port (443, then 8443, 10000, 4443)
  and never takes over something else you serve.
- Turning it on opens Tailscale and turns it on (keeping settings such as
  `--accept-routes`), and starts T3 Code in the background without taking focus,
  restarting it when it's open without its server.
- The QR code is a one-time T3 Code pairing link (10 minutes), so scanning it
  signs a phone or tablet in; **Pair a device…** makes another. Paired devices
  just open the address shown.
- While it's on, Tailgate brings back Tailscale or T3 Code if either is closed
  or turned off. If it can't, or setup is needed (e.g. logged out), Remote
  access turns off and the popover says why.
- Turning off or quitting revokes the pairing link, removes only Tailgate's own
  share and restores normal sleep, including a share Tailscale wouldn't remove
  while it was off and a sleep block left by a killed earlier run.
- Tailscale and T3 Code rows: red is a setup problem (not installed, not logged
  in or signed in) with **Fix in Terminal…**; orange is just not running, which
  Remote access handles. Status updates every 5 seconds and when either app
  starts or quits.
- Turns itself off at 15% battery when unplugged.
- Preferences via `defaults`: `batteryCutoff`, `servePort`, `pairingMinutes`,
  `checkForUpdates`.
- Checks GitHub for a newer release daily and shows **Update available** with
  **Install…** (`tailgate update`).
- Works with the Tailscale Mac app or a Homebrew CLI-only install.

**Command line**
- `tailgate` (`/usr/local/bin/tailgate`, a symlink into the app): `status`,
  `on`, `off`, `pair` (QR code in the terminal), `fix`, `doctor`, `start`,
  `quit`, `update`, `uninstall`. On, off and pair go through the running app, so the menu
  and the terminal always agree.
- `tailgate update` downloads the latest release, verifies its checksum,
  signature and version, swaps the app in place and relaunches it.
- `tailgate fix` / `doctor` (`doctor.sh`) checks and repairs Tailscale, T3 Code
  (installed, server running, signed in, an agent provider, pairing) and
  Tailgate itself.

**Install**
- One-line installer: `curl -fsSL …/scripts/get.sh | sh` downloads the latest
  release, verifies it and installs everything; running it again updates.
- One admin prompt installs the sleep helper
  (`/usr/local/libexec/tailgate-helper`), a narrow `sudoers` rule and the
  `tailgate` command. `install.sh` and the app's first toggle both do it;
  `tailgate uninstall` removes everything.
- Only one copy of the app runs per user, wherever it's launched from.
- Universal binary (Apple silicon + Intel), hardened runtime, DMG and zip
  release script.
