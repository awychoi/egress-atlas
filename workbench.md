---
treatment: hero
order: 50
kicker: Pi-hole · SwiftUI + Metal
banner: docs/assets/screenshots/egress-atlas.jpg
banner_alt: Egress Atlas demo showing the DNS globe, network index, query feed and the HOST globe in the background.
logo: docs/assets/workbench-logo.svg
logo_light: docs/assets/workbench-logo-light.svg
meta:
  - label: How it started
    value: "I was reviewing my Pi-hole log and sparked an idea for a fun DNS explorer, inspired by games like Lumines and Tetris Effect. It became a native macOS app with two globes: the network's DNS traffic and this Mac's own live traffic."
  - label: Built with
    value: Swift 6 · SwiftUI · MetalKit
link:
  href: https://github.com/awychoi/egress-atlas
---

## What it is

Egress Atlas is a native macOS observatory that shows two traffic fields in one instrument: Pi-hole DNS lookups across the network on a warm globe, and this Mac's own live sockets on a cool globe. Orbs recoil on impact, blocked DNS queries raise a red shield, new destinations bloom into existence, and retiring ones shatter into fragments; pressing **G** moves focus between the two globes.

Read-only Pi-hole access and local socket counters, with the API password stored in the macOS Keychain.
