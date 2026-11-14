# setPilot

A small native macOS app (SwiftUI) for controlling a single WiZ RGB bulb, mainly for experimenting
with raw RGBCW values.

## Features

- Sliders (and exact-value fields) for **R, G, B, cool white, warm white** and **dimming**, sent as
  raw `setPilot` values. The last payload sent is shown so you can copy it.
- **Temperature** (Kelvin) and **scene** (with speed) modes.
- **Discovery** on every IPv4 interface's broadcast address, using the same `registration`
  broadcast as [pywizlight](https://github.com/sbidy/pywizlight).
- **Live updates**: registers with the bulb for `syncPilot` pushes (UDP 38900) so the sliders follow
  changes made from the WiZ app or a remote.
- Reads `getModelConfig` to set the minimum dimming level and the Kelvin range; a Device section
  shows the raw `getSystemConfig` / `getModelConfig` / `getUserConfig` / `getPower` results and
  offers reboot and factory reset.
- Retries one-off commands the way pywizlight does (up to 6 sends with backoff).

Not supported: signed requests (firmware that requires the `udp_signing_key` from the WiZ app),
multiple bulbs, dual-head and fan devices.

## Requirements

macOS 14 or later, and Swift 5.9 or later (Xcode or the Command Line Tools).

## Build and run

```bash
swift run
```

When run this way, macOS asks for Local Network access on behalf of your terminal.

To build an ad-hoc-signed `setPilot.app` instead:

```bash
./build-app.sh
```

Every push is also built on GitHub Actions, which uploads a zipped `setPilot.app` as an artifact.
It's ad-hoc signed, so after downloading it you'll need to clear the quarantine flag
(`xattr -dr com.apple.quarantine setPilot.app`) or approve it in System Settings › Privacy & Security.

## Notes

- The first discovery may happen before you've granted Local Network access and find nothing;
  press Find again.
- Live updates need port 38900 free (e.g. not used by Home Assistant on the same Mac) and the bulb
  entered as an IPv4 address.
- Setting R, G, B, C and W all to 0 makes the bulb return an error rather than turn off; use Off.

## Protocol

JSON over UDP port 38899, e.g.:

```json
{"method":"setPilot","params":{"r":255,"g":0,"b":0,"c":0,"w":0,"dimming":100}}
```
