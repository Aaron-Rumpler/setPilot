# setPilot

A small native app (SwiftUI) for controlling a single WiZ RGB bulb, mainly for experimenting with
raw RGBCW values: on the Mac, with an iPhone app and an Apple Watch app alongside.

## Features

- Sliders (with exact-value fields and steppers) for **R, G, B, cool white, warm white** and
  **dimming**, sent as raw `setPilot` values. The last payload sent is shown, syntax-highlighted,
  with a button to copy it as JSON.
- Every change is read back from the bulb; values it ignored or adjusted are flagged.
- Each `setPilot` carries only what changed: the colour (all five channels, the temperature or the
  scene), dimming or speed. The firmware ignores some valid parameters when they're combined with
  others, and this doesn't undo changes made meanwhile by other apps.
- Changes never switch the bulb on or off: a `setPilot` to a bulb that's off carries
  `"state": false` (one without `state` switches it on), and only the power switch changes it.
- **Temperature** mode: the slider's track shows the colour of each temperature, uses a mired scale
  so warm whites get more room, and snaps to 50 K. **Scene** mode with speed.
- **Menu bar item**: a lightbulb (lit inside when the bulb is on) with a panel holding the power switch
  and the same light controls as the window. The app keeps running in the menu bar when the window
  is closed: it has a Dock icon only while a window is open, ⌘Q just closes its windows, and the
  panel's Quit button really quits. Settings can open it at login, menu bar only.
- **Bulb picker** in the window and the menu bar panel: opening it searches every IPv4 interface's
  broadcast address (the same `registration` broadcast as
  [pywizlight](https://github.com/sbidy/pywizlight)) and lists the bulbs that answer with their IP,
  reverse-DNS name and MAC; an IP address or DNS name can also be typed. The chosen bulb is
  remembered and only changes when you choose another. On first launch the app searches by itself
  (asking for Local Network access first) and picks the bulb if there's only one.
- **Bulb names**: name bulbs from the picker (pencil) or the Device panel. Names are kept on this Mac,
  keyed by MAC address (the WiZ app's names are in WiZ's cloud, not on the bulb).
- The chosen bulb is also remembered by MAC: a different bulb answering at the saved address is
  ignored, and if the bulb stops answering (for example its IP changed) the app finds it again by
  MAC and reconnects (addresses entered as DNS names are left to DNS).
- **Live updates**: registers with the bulb for `syncPilot` pushes (UDP 38900) so the controls
  follow changes made from the WiZ app or a remote. The status shows "none yet" until the first
  push arrives, since registering doesn't prove pushes get through a firewall.
- Reads `getModelConfig` to set the minimum dimming level and the Kelvin range; the Device panel
  shows the MAC address, module and firmware, the raw `getSystemConfig` / `getModelConfig` /
  `getUserConfig` / `getPower` results (in a popover from the ⓘ button), and a reboot button.
- Retries one-off commands the way pywizlight does (up to 6 sends with backoff).
- Keyboard: arrow keys step sliders (50 K for temperature), ⌘R syncs.
- **Presets**: save the light as it is (colour, temperature, scene or custom scene, with its
  brightness) and apply it with one click, from the window or the menu bar panel. Applying a preset
  switches the bulb on. Right-click a preset to rename, update, move or delete it.
- **Custom scenes** (Window › Custom Scenes, or the pencil next to the scene picker): up to 12
  steps, each with a colour (RGBCW or a temperature), a level, how long it holds and how long it
  fades into the next. They're played inline (`setPilot` with `sceneId` 300 and an `elm`
  definition), so nothing stored on the bulb is touched; the bulb can't read definitions back, so
  they're kept in setPilot. They appear in the scene picker after the bulb's own.
- **Fade time** (Settings): the `trans` parameter, in milliseconds, for every change, or the bulb's
  own fade (shown from `getUserConfig`). Turning off always uses the bulb's fade-out.

## iPhone and Apple Watch

The iPhone app has the same controls, presets and custom scenes (its own, kept on the iPhone), plus
Shortcuts actions: apply a preset, switch on or off, set the brightness, and make it brighter or
dimmer (`dimDelta`, relative to wherever the bulb is). Through the Shortcuts app those reach Siri,
the Action button, and Control Center and the Lock Screen (a Shortcuts control).

The iPhone app doesn't search the network: broadcasting needs Apple's multicast entitlement (paid
accounts only), and probing every address on a network isn't acceptable on networks you don't own.
Enter the bulb's IP address or DNS name; a DNS name keeps working if the address changes.

The Watch app's main screen is the presets (tap to apply), with power above them; Controls has
everything else (mode, channels, temperature, scene, speed, brightness, using the Digital Crown),
and custom scenes can be played. watchOS doesn't let apps send UDP (only while streaming audio), so
the watch sends every command to the iPhone app over WatchConnectivity, which talks to the bulb and
replies with its state. The iPhone has to be in Bluetooth or Wi-Fi range of the watch; the iPhone
app doesn't need to be open. The presets and last state are cached on the watch for when it isn't.

Both run on iOS 26 and watchOS 26 and work with a free Apple developer account (no paid-only
capabilities; free signing lasts 7 days, so reinstall from Xcode weekly).

Not supported: storing scenes on the bulb (`setExtendedLightMode`: its 20 slots can't be read
back, so writing one could overwrite a scene the WiZ app stored), signed requests (firmware that requires the `udp_signing_key` from the WiZ app),
multiple bulbs, Rhythm and sync-box scenes (shown when the bulb is in one, but not settable),
dual-head and fan devices.

## Colour temperature colours

The Kelvin track and the cool/warm white sliders show black-body colours: the CIE 1931 Planckian
locus (Kim et al. 2002 fit), converted to sRGB. Rendered exactly as measured against the display's
white, 4200 K looks orange, which isn't how a bulb looks in a room, so the colours are adapted (CAT02
von Kries) as if your eyes were adapted to 4500 K: the orange is gone by 4200 K and 6500 K looks
clearly cooler.

For testing, **Settings** (⌘,) has a slider for the adapting white, with a preview. It's stored in
user defaults, so it can also be set from the terminal:

```bash
defaults write nz.aaronrumpler.setPilot adaptingWhite -float 4800
```

## App icon

`Common/AppIcon.icon` is an Icon Composer package (Liquid Glass, SVG layers) generated by
`tools/make_icon_layers.py`: five sliders in the app's channel colours, with variants for the Dark,
Clear and Tinted icon styles. The white channels' colours are baked in at the adapting white; to
regenerate with another value:

```bash
python3 tools/make_icon_layers.py 4800
```

## Requirements

macOS 14 or later; iOS 26 and watchOS 26. Building needs Xcode 26 (for the Icon Composer app icon;
Xcode 26 also generates the fallback icons for older macOS).

## Build and run

Open `setPilot.xcodeproj` in Xcode and run. Or from the command line:

```bash
xcodebuild -project setPilot.xcodeproj -target setPilot -configuration Release build
```

```bash
open build/Release/setPilot.app
```

The project signs to run locally (ad hoc) by default; pick your team under Signing & Capabilities if
you want it signed with your own certificate. The app is sandboxed with outgoing and incoming network
access (the latter for live updates). The project uses Xcode's folder-synchronised groups, so any
file added to a folder is picked up without editing the project:

| Folder | Built into |
|---|---|
| `setPilot/` | the Mac app |
| `setPilotiOS/` | the iPhone app (scheme "setPilot iOS", which also builds and embeds the watch app) |
| `setPilotWatch/` | the Watch app |
| `Core/` | Mac and iPhone: the bulb protocol, model, presets and custom scenes, shared views |
| `Common/` | all three: light types, colour maths, the watch messages, the icon |

To run on your iPhone and watch, choose the "setPilot iOS" scheme, pick your (free or paid) team for
both the iOS and Watch targets under Signing & Capabilities, and run.

Pushes to `main` and pull requests are built on GitHub Actions (macOS 26): the Mac app, and the
iPhone app with the watch app (unsigned, to check it compiles). The Mac app is uploaded as an
artifact. It's ad-hoc signed, so after downloading it you'll need to clear the
quarantine flag or approve it in System Settings › Privacy & Security:

```bash
xattr -dr com.apple.quarantine setPilot.app
```

## Notes

- Local Network access is required. If it was denied, turn it on in System Settings › Privacy &
  Security › Local Network.
- Live updates need port 38900 free (e.g. not used by Home Assistant on the same Mac). A bulb chosen
  by DNS name is resolved to its IPv4 address for them.
- R, G, B, C and W don't correspond directly to LED drive: the firmware remaps them (with a white
  LED lit they act more like proportions), and dimming is applied separately.
- Scene `speed` only takes effect when sent on its own (a firmware bug), so setPilot sends it as a
  separate `setPilot`.
- Setting R, G, B, C and W all to 0 makes the bulb return an error rather than turn off; use the
  power switch.

## Protocol

JSON over UDP port 38899, e.g.:

```json
{"method":"setPilot","params":{"r":255,"g":0,"b":0,"c":0,"w":128}}
```
