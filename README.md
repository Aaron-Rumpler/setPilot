# setPilot

A small native macOS app (SwiftUI) for controlling a single WiZ RGB bulb, mainly for experimenting
with raw RGBCW values.

## Features

- Sliders (with exact-value fields and steppers) for **R, G, B, cool white, warm white** and
  **dimming**, sent as raw `setPilot` values. The last payload sent is shown, with a button to copy
  it as JSON.
- Every change is read back from the bulb; values it ignored or adjusted are flagged.
- **Temperature** mode: the slider's track shows the colour of each temperature (Planckian locus,
  CIE 1931 2°, rendered in sRGB), uses a mired scale so warm whites get more room, and snaps to
  50 K. **Scene** mode with speed.
- **Discovery** on every IPv4 interface's broadcast address, using the same `registration`
  broadcast as [pywizlight](https://github.com/sbidy/pywizlight).
- **Live updates**: registers with the bulb for `syncPilot` pushes (UDP 38900) so the controls
  follow changes made from the WiZ app or a remote.
- Reads `getModelConfig` to set the minimum dimming level and the Kelvin range; a Device section
  shows the MAC address, the raw `getSystemConfig` / `getModelConfig` / `getUserConfig` / `getPower`
  results (in a popover), and a reboot button.
- Retries one-off commands the way pywizlight does (up to 6 sends with backoff).
- Keyboard: arrow keys step sliders (50 K for temperature), ⌘R syncs.

Not supported: signed requests (firmware that requires the `udp_signing_key` from the WiZ app),
multiple bulbs, dual-head and fan devices.

## Requirements

macOS 14 or later; Xcode 16 or later to build.

## Build and run

Open `setPilot.xcodeproj` in Xcode and run. Or from the command line:

```bash
xcodebuild -project setPilot.xcodeproj -target setPilot -configuration Release build
open build/Release/setPilot.app
```

The project signs to run locally (ad hoc) by default; pick your team under Signing & Capabilities if
you want it signed with your own certificate. The app is sandboxed with outgoing and incoming network
access (the latter for live updates). The project uses Xcode 16's folder-synchronised groups, so any
file added under `setPilot/` is picked up without editing the project.

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
