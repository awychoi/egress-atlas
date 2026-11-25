<p align="center">
  <img src="docs/assets/workbench-logo.svg" width="300" alt="Egress Atlas app icon">


Egress Atlas is a macOS app that turns your Pi-hole's DNS traffic into a map. Devices on your network sit on the surface of a globe, the domains they look up sit inside it, and every query travels along a wire between them. Allowed lookups glow gold, blocked lookups coral, and new or disappearing destinations play short animations instead of filling another log table. It starts with an empty DNS globe until a Pi-hole is connected; **Settings → Use demo** loads the offline sample network when you want to preview the instrument.

![Egress Atlas replaying the last six hours](docs/assets/screenshots/egress-atlas-replay.png)

When you connect a Pi-hole v6 server, Egress Atlas reads recent DNS queries and keeps polling for new ones. The dock can also replay the archive: open **History**, choose the last hour, six hours, day or week, pick a start time, and play the queries back as a looping or one-shot show. The connection is direct and read-only: the app never changes your Pi-hole configuration, keeps the API password in the macOS Keychain, and sends no data anywhere else. Set a local alias for any device or DNS destination and its cards will use that name; a device alias replaces the name while its IP stays visible, and Display → Show domain with alias adds the original domain beside a destination alias. Drag to orbit the globe, right-drag to move it around the window, and leave auto-orbit on to keep it spinning while you do; the surrounding starfield and space dust stay anchored while the globe moves.

A second, cool globe shows **this Mac's own live traffic**: apps and services on its shell, the domains or endpoints they reach inside it, and byte flow both ways. Press **G**, use the DNS/HOST switcher, or click the inactive globe to move focus: the camera makes a 180° orbit around the clicked background globe and ends on its exact opposite side, so the old foreground stays put and becomes the out-of-focus background. The unfocused globe has its own slow orbit and never takes the foreground. Host traffic is read from macOS's socket counters, with no packet capture, no history and no background collector. Domain names are inferred from Pi-hole's dnsmasq log and local resolution; endpoints without a name stay as IP:port, and HOST still works when Pi-hole is not connected.

## Requirements

- macOS 15 or later
- Xcode 16 or later (Swift 6 toolchain)
- A Pi-hole v6 server on your local network, if you want live DNS data and host domain names

## Build and run

Egress Atlas is not distributed through the App Store and is not notarized. Build it from source and sign it locally:

```sh
git clone https://github.com/awychoi/egress-atlas.git
cd egress-atlas/macos
./scripts/build-app.sh
open "dist/Egress Atlas.app"
```

The script builds with SwiftPM, assembles the app bundle, renders its icon and signs the result. It ad-hoc signs by default, which is enough to run the app on the machine that built it.

For a stable local signing identity, create a self-signed code-signing certificate named `Egress Atlas Local` in Keychain Access (Certificate Assistant → Create a Certificate…, choose Code Signing), then build with it:

```sh
SIGN_IDENTITY="Egress Atlas Local" ./scripts/build-app.sh
```

The stable identity keeps macOS from treating each rebuild as a different app, so local-network permissions persist. Launch the built `.app` rather than the bare SwiftPM executable; the bundle is what gives macOS the app identity. `./scripts/build-app.sh --debug` produces `dist/Egress Atlas Debug.app`.

If macOS blocks the app after it has been moved or downloaded, allow it in **System Settings → Privacy & Security**, or remove the quarantine flag:

```sh
xattr -dr com.apple.quarantine "dist/Egress Atlas.app"
```

## Connect a Pi-hole

Open **Settings → Source** (or the source chip in the top bar), enter your Pi-hole's URL — for example `http://pi.hole` — and its API password, then connect. Egress Atlas imports a six-hour snapshot and polls the last three minutes. History playback reads from Pi-hole's on-disk query database, so the app may take a moment to assemble a week. The app reads only; it never writes configuration back to Pi-hole.

## About Pi-hole

Egress Atlas works with [Pi-hole](https://github.com/pi-hole/pi-hole), the open-source network-wide ad blocker. Egress Atlas is an independent project and is **not affiliated with, endorsed by, or supported by the Pi-hole project**.

## Technical write-up

The scene model, dual-globe layout, Metal rendering pipeline, host-traffic source, Pi-hole client, packaging and self-signing are documented in [TECHNICAL.md](TECHNICAL.md).

## Development

Enable the repository's Git hooks once per clone:

```sh
./scripts/install-git-hooks.sh
```

The pre-commit hook scans staged changes for secrets with [gitleaks](https://github.com/gitleaks/gitleaks) and refuses to commit unscanned if gitleaks is unavailable. Install it with `brew install gitleaks`. Because the hook is wired through `core.hooksPath`, it runs for commits made from Xcode, VS Code, or another Git client too, and it searches Homebrew's install locations itself so those clients do not need your shell's `PATH`. For a verified false positive, `git commit --no-verify` bypasses it.

## License

Egress Atlas. Copyright © 2026 wychoi.

Egress Atlas is free software under the [GNU General Public License v3.0](LICENSE) (GPLv3): you can redistribute it and/or modify it under the terms of the GPLv3. It is distributed **without any warranty**, to the extent permitted by law.
