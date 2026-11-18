# Egress Atlas — Technical Notes

Egress Atlas is a native macOS app that shows Pi-hole DNS traffic as a live globe. Devices sit on the shell, domains sit inside it, and each query travels the wire between them. It uses Swift 6, SwiftUI, MetalKit and AppKit and has no third-party dependencies.

The source is in `macos/`; README artwork and the website lockups are in `docs/assets/`. The user-facing overview is [README.md](README.md).

## The scene

Devices are clients on the network: laptops, phones, TVs, NAS boxes. Each appears on the globe's outer shell as a blue orb with a tangent pad, orbiting motes and a label.

Destinations are DNS domains. They sit inside the globe, sized on a log scale by query volume and colored gold for allowed lookups or coral for blocked ones. Each destination has an instrument ring, a camera-facing light arc and a tilted orbit.

A wire represents a device-to-destination relationship, and queries travel it as a comet with a tapered, jittered trail. Device-to-device traffic uses an icy arc above the shell.

The layout follows traffic affinity. A destination is pulled toward the weighted centroid of the devices that query it, and devices that exchange local traffic drift together. A 3D relaxation spreads the bodies, with the globe radius easing between 6.0 and 9.45 world units. At the cap, clearance shrinks and a dense All population can overlap into a bright field. The full globe stays visible; the population and history controls set the density.

The history window runs from one hour to seven days and follows each body's `lastSeen`. Destinations play an emergence or retirement as they cross the window; devices fade out with their wires. An aged-out device that receives a query keeps its shell position, gets a new wire, and plays an appearance study when the pulse arrives. The Devices index lists every device, its last-seen age, and dims rows outside the window.

## Runtime and rendering

`main.swift` provides four headless modes: `--snapshot`, `--self-test`, `--live-test` and `--make-icon`. Otherwise it starts the AppKit app: a full-size-content `NSWindow` with SwiftUI chrome over a full-window `MTKView`.

`AtlasRuntime` owns the network, source, selection, overlays, camera and playback state. The view's display link advances the runtime and calls `MTKView.draw()` directly. `ATLAS_CLOCK=timer|async` selects fallback clocks for measurement. The direct draw avoids an extra AppKit display pass that used to cap presentation near 24 fps.

The renderer uses a linear HDR `rgba16Float` scene with 4× MSAA, double-buffered post targets and a final `bgra8Unorm` pass. Depth of field derives from the globe's front intersection, so it needs no second scene pass. Bloom runs a five-mip chain capped at 960×540 device pixels. ACES tone mapping and sRGB transfer are followed by vignette and grain, and render scale is capped at 1.75×.

The field includes a dotted shell, dust, a latitude/longitude grid, three armillary rings, horizon ticks, a star-dome shader, atmosphere and glass shells, and a coral/gold limb sprite. Device and destination geometry, wire curves and hit shaders are native Metal.

## Pi-hole source

`PiHoleClient` is a direct, read-only Pi-hole v6 client. It authenticates with `POST /api/auth`, requests `GET /api/queries` for a six-hour window of up to 5,000 rows, and keeps the session id in memory.

The Source panel offers 25, 50, 100 and All populations. Top 100 is the default. Limited modes keep the busiest clients and destinations, with blocked destinations reserved; All admits every client and domain in the sample. The snapshot becomes the same graph as the demo, and the history window decides which orbs are visible.

`PiHoleSource` imports unseen query ids and polls the last 180 seconds every 1.5 seconds. Rows outside the selected population count as off-graph. The client sends no configuration, aliases or filters back to Pi-hole. The URL and certificate preference live in user defaults; the API password lives in the login Keychain under `com.egressatlas.pihole`; the request session is ephemeral. The app remembers the last source and reconnects from the saved URL and Keychain, falling back to demo with a notice if Pi-hole is unreachable. Use `https://` for a remote Pi-hole; `http://` works locally.

## Interaction

Display and motion settings persist in user defaults: labels, history window, auto-orbit, window-drag coupling, response, node recoil, study speed and the hit-plane overlay. Playback, auto tour, pause and the outcome filter last for the session.

The dock has zoom, rotate, reset, top view, Face hit and auto-orbit. Dragging the field orbits the camera; moving the window leaves the camera still unless Display → Window drag spins globe is enabled. The window clamps to 680 × 700 so the top bar and transport timeline stay intact. Keyboard shortcuts cover camera, playback, panels and search.

Picking ranks hits by screen distance to each body's projected center, which keeps a far-shell device addressable when a foreground orb's larger hit volume covers the ray. Hovering shows a tag; double-clicking orbits to the body. The Metal view hit-tests SwiftUI chrome, and cursor updates share one authority to prevent flicker. Controls have VoiceOver labels; the globe is a summarized accessibility element, and the rails and inspector rows are fully labeled.

## Motion

Impacts play one of five studies: Eclipse, Ember bloom, Prism fracture, Resonance and the 360° Containment shield for blocked destinations. New destinations use Spiral convergence, Arc weld, Seed bloom, Scan assembly or Redaction for blocked ones. Retiring destinations use Tectonic rupture or Core collapse.

Rapid hits on one destination stack, and each blast keeps its inbound angle. Blocked destinations stay coral and use containment; their studies follow the body's live layout movement.

## Build and signing

```sh
cd macos
./scripts/build-app.sh          # release: dist/Egress Atlas.app
./scripts/build-app.sh --debug  # debug:  dist/Egress Atlas Debug.app
```

The script builds with SwiftPM, assembles the bundle, copies resources, renders the icon and signs the app. The deployment target is macOS 15, and there are no third-party Swift dependencies. Debug builds are `-Onone`; benchmark and ship the release build.

The bundle is ad-hoc signed by default and not notarized. Ad-hoc signing runs the app on the machine that built it. For a stable local identity, create a self-signed code-signing certificate named `Egress Atlas Local` in Keychain Access and build with:

```sh
SIGN_IDENTITY="Egress Atlas Local" ./scripts/build-app.sh
```

The script selects that identity automatically; `SIGN_IDENTITY` overrides it. Named identities get the hardened runtime, and the stable identity keeps macOS local-network permissions across rebuilds. For a quarantined build, use System Settings → Privacy & Security or:

```sh
xattr -dr com.apple.quarantine "dist/Egress Atlas.app"
```

The icon comes from the bundled 1024 px SVG master at [`macos/Sources/EgressAtlas/Resources/brand-app-icon.svg`](macos/Sources/EgressAtlas/Resources/brand-app-icon.svg). The build writes ten iconset sizes; `iconutil` makes `AppIcon.icns`. The master is clipped into Apple's macOS squircle: 824 × 824 content on a 1024 canvas, a 100 px transparent margin and a 185.4 px corner radius. A missing master fails the build.

At launch the app sets `NSApplication.applicationIconImage`, so the Dock, app switcher and About panel use the same artwork as the bundle icon.

## Verification

```sh
cd macos
swift build
.build/debug/EgressAtlas --self-test

.build/debug/EgressAtlas --snapshot --ui --rails \
  --width 1600 --height 1000 --scale 1.5 \
  --out ../docs/assets/screenshots/egress-atlas.png
```

`--self-test` checks the demo model, picking, effects, focus, windows and the Metal renderer; a pass ends with `metal renderer OK`. `--snapshot` writes a deterministic still without screen-capture permission. `--live-test --url http://127.0.0.1:8080 --password testpass` runs the client against a local mock; `testpass` is a fixture.

For pacing, run with `ATLAS_DIAGNOSTICS=1 ATLAS_LOG=/tmp/atlas.log` and grep for `pacing mode` and `present fps`. `ATLAS_LABELS=all` forces the dense label path.

## Performance

On the M1 Max development host at 1600×1000, the demo and live 100 views use 1.1–1.9 ms of frame work and 1.7 ms of GPU time. The display link presents at 71–72 fps on a 72 Hz display and 60 fps on 60 Hz. The async timer fallback reaches about 56 fps.

A live All population is layout-bound: 12 devices and 900 destinations spend about 10 ms in the destination pair relaxation plus about 2 ms of GPU, presenting at 53–58 fps. The label overlay adds little there.

Three choices keep the frame budget bounded. Local-flow affinity is indexed once per scene into a sparse, bidirectional device table. Published summaries compare before assigning, recent-query rows rebuild only while the Queries rail is open, and the inspector revision changes only when a selection exists. Labels resolve at the field rate for selected and hovered bodies; above two labels, anchors resolve at 24 Hz and interpolate, and dense modes cap at 64 candidates and 24 tags. Above 200 destinations the overlay drops to four tags at 12 Hz.

## Privacy and security

The demo runs offline with local assets. The app has no accounts, telemetry or remote code and talks only to the configured Pi-hole origin. The API password lives in the login Keychain; the URL and certificate preference stay in user defaults. Pi-hole access is read-only.

## Limits

Live data comes from a six-hour sample. The 25–100 populations stay compact; All includes every client and domain and can overlap into a bright field. Multi-day history, replay and alias editing are absent; live data lives in memory. The build is ad-hoc signed and not notarized. The globe is a summarized accessibility element, while the rails and inspector rows are fully labeled. Field labels stay compact at small window sizes. Destination relaxation is pair-based, so a live All population is layout-bound around 57 fps on a M1 Max MBP.
