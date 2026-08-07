# TLocation

A minimal iOS app that does one thing: **simulate your device's GPS location** — a single map screen where you drop a pin and your iPhone reports that position system-wide. No computer required after initial setup.

> **Origin & attribution:** TLocation is a **derivative work of [StikDebug](https://github.com/StikDebug/StikDebug)** by Stephen Bove (Stik) and the StikDebug contributors — not an original project. The entire device-communication core (pairing-file handling, loopback tunnel, Developer Disk Image mounting, the `idevice` FFI, background keep-alive, and the location-simulation engine itself) originates from StikDebug; this fork removes StikDebug's other features, adds two locate buttons, and rebrands the app. Licensed **AGPL-3.0**, same as upstream — see [LICENSE](LICENSE) (preserved unchanged from StikDebug).

## Features

- Drop a pin anywhere (tap, search, or coordinates) and simulate that location
- **Locate Me** button: centers the map on your real GPS position
- **Return to Real Location** button: clears the simulated location and restores your device's real GPS position (only enabled while a simulation is active)
- Bookmarks for frequent locations
- Keeps simulating in the background (silent-audio + low-accuracy-location keep-alive)
- URL scheme: `tlocation://simulate-location?lat=37.3349&lon=-122.0090`, `tlocation://clear-location`

## Requirements

- iOS 17.4+ (on-device setup; no Mac/PC needed after you have a pairing file)
- [LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) (free) — loopback VPN so the app can talk to the device it runs on
- A **pairing file** for your device — see the [pairing file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md)
- **Wi-Fi joined to a network when starting a simulation.** iOS only exposes the on-device pairing service while Wi-Fi is associated (the network needs no internet — another phone's hotspot works). On recent iOS builds, cellular-only / hotspot-toggle tricks do NOT work. Once simulation is running, it may survive brief network changes while the VPN stays up.

## Install via SideStore

1. Download the latest `TLocation.ipa` from [Releases](../../releases) (built unsigned by CI).
2. Open SideStore → **+** → pick the `.ipa`. SideStore signs it with your Apple ID and installs it.
3. Launch TLocation, import your pairing file, connect LocalDevVPN, wait for the status banner to turn green.

AltStore works the same way.

### SideStore source

Add this source in SideStore to get updates automatically: `https://raw.githubusercontent.com/truongkma/t-location/main/source.json`.

Note: the source lists no installable version until the first release tag is pushed. Until then it will appear empty in SideStore — install the `.ipa` manually as described above.

## Build from source

```bash
xcodebuild -project TLocation.xcodeproj -scheme TLocation -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Pushing a version tag (e.g. `1.0`) makes CI attach an unsigned IPA to a GitHub release.

## What was removed from StikDebug

JIT enabling, JavaScript scripting, console/syslog viewer, process inspector, device info, app-expiry viewer, App Intents. Only location simulation (and the infrastructure it needs) remains.

## Credits & License

- **[StikDebug](https://github.com/StikDebug/StikDebug)** — the upstream project TLocation is derived from, © Stephen Bove (Stik) and the StikDebug contributors. If TLocation is useful to you, star and support the original project. Setup guides live in [StikDebug-Guide](https://github.com/StikDebug/StikDebug-Guide).
- [idevice](https://github.com/jkcoxson/idevice) by jkcoxson — Rust library for Apple device services (bundled here as `libidevice_ffi.a`, unchanged)
- [LocalDevVPN / StosVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044) — loopback VPN that makes on-device pairing possible
- App icon: original artwork for this fork (blue gradient from StikDebug's icon palette, pin glyph new)

**License: AGPL-3.0** — inherited from StikDebug and applying to this entire derivative; the complete corresponding source is this repository. See [LICENSE](LICENSE).
