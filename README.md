# Tailgate

Menu bar app that makes this Mac reachable from your phone, tablet or another
Mac: it keeps the lid awake, makes sure Tailscale is connected, makes sure
T3 Code is running, and shares T3 Code on your tailnet (with a QR code).

## Screenshots

| Menu bar popover | Remote access on (QR code) |
|--|--|
| ![Tailgate popover with Tailscale and T3 Code health](docs/screenshots/popover.png) | ![Tailgate sharing T3 Code with a QR code](docs/screenshots/remote-on.png) |

## Use case: open T3 Code from your phone

### Private: over your tailnet (Tailscale Serve)

This is what Tailgate does by default. Only devices signed in to your tailnet
can reach it.

1. Install Tailscale on your phone, sign in with the same account as the Mac,
   and keep it connected (also on mobile data).
2. On the Mac, click the Tailgate icon and turn on **Remote access**. Tailgate
   connects Tailscale, starts T3 Code in the background and shares it.
3. Scan the QR code with the phone's camera. It is a one-time T3 Code pairing
   link that signs the phone in; it expires after 10 minutes. For another
   device, click **Pair a device…** for a new code.
4. From then on the phone just opens the address shown under the QR code, e.g.
   `https://my-mac.tail1234.ts.net`. Close the lid and keep working.

Under the hood this is the same as:

```sh
tailscale serve --bg --https=443 3773   # T3 Code listens on localhost:3773
t3 auth pairing create --base-url https://my-mac.tail1234.ts.net   # the QR link
```

T3 Code only listens on `127.0.0.1`, so `http://my-mac:3773` won't work from
the phone; it has to go through Tailscale Serve. If HTTPS certificates are not
enabled for your tailnet, Tailgate falls back to
`http://my-mac.tail1234.ts.net:8080`.

If the phone can't load the page, check that its Tailscale app says
*Connected*, then run `tailscale ping <phone-name>` on the Mac; no reply means
the phone isn't on the tailnet.

### Public: on the internet (Tailscale Funnel)

Use Funnel when the other device can't run Tailscale, such as a borrowed
laptop. Tailgate doesn't turn Funnel on for you; do it by hand after Remote
access is on, and pair the device with **Pair a device…** as usual:

```sh
tailscale funnel --bg 3773   # same https://my-mac.tail1234.ts.net URL, now public
tailscale funnel status
```

Funnel has to be allowed for this device in your tailnet policy (the `funnel`
node attribute; the CLI prints a link to enable it if it isn't). Anyone with
the URL can reach T3 Code's sign-in page, so turn it off when you're done:

```sh
tailscale funnel --https=443 off
```

Turning Remote access off or quitting Tailgate runs `tailscale serve reset`,
which also removes the Funnel.

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
- Quitting the app revokes an unused pairing link, resets Tailscale Serve and
  restores normal sleep.
- While Remote access is on, Tailgate restarts Tailscale or T3 Code in the
  background if either drops. It never starts a login or restarts an app you
  have open on its own; those show in the popover with **Fix in Terminal…**.
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
