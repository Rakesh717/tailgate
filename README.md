# Tailgate

Menu bar app that makes this Mac reachable from your phone, tablet or another
Mac: it keeps the lid awake, makes sure Tailscale is connected, makes sure
T3 Code is running, and shares T3 Code on your tailnet (with a QR code).

## Install

```sh
./install.sh      # builds, copies to ~/Applications, launches, then runs the doctor
```

The first toggle asks for your admin password once. That installs a small root
helper (`/usr/local/sbin/tailgate`) and a narrow `sudoers` rule, so later
toggles are instant. To do it by hand: `sudo /bin/sh ./install-helper.sh`.

## Health check

The popover always shows Tailscale and T3 Code status:

| | Checks |
|--|--|
| Tailscale | installed, daemon up, logged in, not turned off or awaiting approval |
| T3 Code | installed, running, signed in |

When either is red, **Fix in Terminal…** runs `doctor.sh --fix`. The same
script works standalone:

```sh
./doctor.sh          # report only (exit 1 on problems)
./doctor.sh --fix    # offer to brew-install, log in, launch what is missing
./doctor.sh --yes    # same, no prompts
```

It also checks the node-key expiry, that the T3 server is listening and
exposed through Tailscale Serve, that an agent provider (Claude Code, Codex or
OpenCode) is logged in, and that the root helper works. Toggling Remote access
on runs the same prerequisites and stops with a specific message if one fails.

## Safety

- Turns itself off at 15% battery when unplugged.
- Quitting the app resets Tailscale Serve and restores normal sleep.
- Only one instance runs; a second launch exits immediately.
- The display still turns off; only system sleep is blocked. Keep the Mac on a
  hard surface, since a closed lid runs warm.

## Manual override

```sh
sudo pmset -a disablesleep 0   # normal sleep
tailscale serve reset          # stop sharing
```

## Uninstall

```sh
rm -rf ~/Applications/Tailgate.app
rm -f ~/Library/LaunchAgents/com.rakesh717.tailgate.plist
sudo rm -f /usr/local/sbin/tailgate /etc/sudoers.d/tailgate
sudo pmset -a disablesleep 0
tailscale serve reset
```

## Releasing

```sh
echo 1.1.0 > VERSION                       # also add a CHANGELOG.md entry
./scripts/release.sh                       # dist/Tailgate-1.1.0.{dmg,zip} + SHA256SUMS
```

That build is universal (Apple silicon + Intel) but only ad-hoc signed, so
macOS asks users to right-click → Open the first time. For a trusted build you
need an Apple Developer ID:

```sh
xcrun notarytool store-credentials tailgate --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=tailgate \
  ./scripts/release.sh
```

Pushing a tag `v1.1.0` runs `.github/workflows/release.yml`, which checks the
tag against `VERSION`, builds, and attaches the artifacts to a GitHub release.
`packaging/tailgate.rb` is a Homebrew cask template for your own tap.

## Icon

`Resources/AppIcon.icns` is generated: `swift tools/make-icon.swift .`
