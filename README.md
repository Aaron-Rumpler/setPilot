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
- Three modes, by the same names everywhere: **RGBCW**, **Temperature** and **Scenes** (with speed).
  Temperature's Scale is the bulb's own (`temp`) or one of your CCT scales (Custom CCT, below); the
  kelvin carries over when you switch. The slider's track shows the colour of each temperature,
  uses a mired scale so warm whites get more room, and snaps to 50 K on the bulb's own.
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
  keyed by MAC address, and sync through iCloud in builds with it (the WiZ app's names are in WiZ's
  cloud, not on the bulb).
- The chosen bulb is also remembered by MAC: a different bulb answering at the saved address is
  ignored, and if the bulb stops answering (for example its IP changed) the app finds it again by
  MAC and reconnects (addresses entered as DNS names are left to DNS).
- **Live updates**: registers with the bulb for `syncPilot` pushes (UDP 38900) so the controls
  follow changes made from the WiZ app or a remote. The status shows "none yet" until the first
  push arrives, since registering doesn't prove pushes get through a firewall.
- Reads `getModelConfig` to set the minimum dimming level and the Kelvin range; the Device panel
  shows the MAC address, module and firmware, the raw replies to every read the bulb answers over
  UDP (all 22 in firmware 1.38.0's method table, Wi-Fi ones included), in a popover from the ⓘ
  button (Bulb & Settings › Device Info on iPhone): each a collapsible section with a copy button,
  errors flagged, and Expand All and Copy All.
- **Shortcuts** (Mac too): apply a preset, switch on or off, set the brightness, brighter or dimmer;
  from the Shortcuts app, Spotlight and Siri.
- **Console** (Window › Console, ⌥⌘K, or Console… on the Last Command panel; on iPhone, Bulb &
  Settings › Console, with the log on its own page): send any method with any params. Known
  methods (the 35 firmware 1.38.0 takes over UDP; it refuses the rest) are in a menu with params to
  start from, a description, and a confirmation for anything that changes what the bulb stores.
  Params are edited as syntax-highlighted JSON, checked as you type, and can be left out
  altogether. A `setPilot` from the console is read back like the controls' own; with "Don't switch
  on" (off by default) it gets `"state": false` while the bulb is off, as the controls' own do. **Raw** edits the whole message instead
  and sends it exactly as typed (it needn't be valid JSON). The reply shows its `result` (or
  `error`); **Full reply** shows the whole message. Format indents the JSON (or puts it on one
  line), and on the Mac the editor and reply share a divider you can drag. Below it, a log of every
  request, reply and live update (with times to the millisecond), filterable, indented or one line
  each, copyable, with a button on each message to put it into the console, and a choice of how
  many entries it keeps.
- Retries one-off commands the way pywizlight does (up to 6 sends with backoff).
- **Round numbers**: sliders (and the watch's Digital Crown) snap to round steps, and the steppers
  and − and + step to the next one: 5 for dimming and other percentages, 50 K for temperatures, 32
  for 0–255 channels, 10 for speed, 100 ms for times. Snapping can be turned off in Settings.
  Finer: hold a slider's knob still for a moment before dragging (Mac and iPhone; a haptic tick
  says it's on), or on the Mac hold Option while dragging, using the arrow keys or clicking a
  stepper. Tapping a value on iPhone or the watch opens a number pad, where − and + (and the
  Crown) step by 1; temperatures and times also have ±10 (on the watch the default, with a button
  to switch to 1s). Keyboard: arrow keys step a focused slider, ⌘R syncs.
- **Presets**: save the light as it is (colour, temperature, scene or custom scene, with its
  brightness) and apply it with one click, from the window or the menu bar panel. Applying a preset
  switches the bulb on. Right-click a preset to rename, update, move or delete it.
- **Custom scenes** (Window › Custom Scenes, or the pencil next to the scene picker): up to 12
  steps, each with a colour (RGBCW or a temperature), a level, how long it holds and how long it
  fades into the next. They're played inline (`setPilot` with `sceneId` 300 and an `elm`
  definition), so nothing stored on the bulb is touched; the bulb can't read definitions back, so
  they're kept in setPilot. They appear in the scene picker after the bulb's own.
- **Compose a change** (Compose… on the Light panel): prepare a new state (any of colour,
  brightness and power) and send it as one `setPilot`. Its fade is the fade time setting (shown, if
  there is one), none (no `trans`), or a value just for this change, say 10 s. It starts
  from the bulb's current state. A scene can have a speed too, which goes in a `setPilot` of its
  own just after (the firmware ignores speed alongside anything else).
- **Light menu** (Mac): switch on or off (⇧⌘P), sync, and the first nine presets on ⌘1–⌘9.
- **Export and import** (Settings on the Mac, Bulb & Settings on iPhone): presets, custom scenes
  and CCT scales as one JSON file, to copy them between devices without iCloud. Importing adds to
  what's there and updates items exported from there before.
- **Custom CCT** (a Scale under Temperature): kelvin through a colour-temperature scale of your
  own, kept per bulb (several per bulb; Window › CCT Scales). A new scale starts as the bulb's own table, rebuilt from
  `getModelConfig` (`cctRange`, `renderFactor`) exactly as firmware 1.38.0 builds it, with the same
  interpolation, so it gives what `temp` gives until you change it. Edit any point's kelvin and
  RGBCW, add points, or extend it below its lowest point along WiZ's own line (red rising to full,
  about 1540 K on this bulb). It's sent as RGBCW; the bulb can't tell it apart, so when the bulb
  reports RGBCW while a scale is in use, setPilot stays on it if the scale gives exactly those
  values at some kelvin (the nearest), and otherwise shows RGBCW. (The bulb's own custom CCT table,
  `setCctTable`, is cloud-only.)
- **Fade** under Dimming: what the main controls send as `trans` (sliders, presets, brighter and
  dimmer): the fade time setting, none, or a value of their own, as in Compose.
- **Fade time** (Settings; off by default, so no `trans` is sent): the `trans` parameter, in milliseconds, for every change, or the bulb's
  own fade (shown from `getUserConfig`). Turning off always uses the bulb's fade-out.

## iPhone and Apple Watch

The iPhone app has the same controls, presets and custom scenes (its own, kept on the iPhone), plus
Shortcuts actions: apply a preset, switch on or off, set the brightness, and make it brighter or
dimmer (`dimDelta`, relative to wherever the bulb is). Through the Shortcuts app those reach Siri,
the Action button, and Control Center and the Lock Screen (a Shortcuts control). It has the console
too (Bulb & Settings › Console).

The iPhone app doesn't search the network: broadcasting needs Apple's multicast entitlement (paid
accounts only), and probing every address on a network isn't acceptable on networks you don't own.
Enter the bulb's IP address or DNS name; a DNS name keeps working if the address changes.

The iPhone remembers the bulbs you've used (Bulb & Settings › Your Bulbs) to switch between.

**Widgets** (iPhone): a Presets widget for the Home Screen (tap a preset; power and brighter/dimmer
on the larger sizes), a Lock Screen bulb status, and Control Center controls for power and for a
preset of your choice. Their actions run in the app in the background on its connection to the
bulb (if the system runs them in the widget extension instead, it sends the request itself).

The Watch app's main screen is power and the presets (tap to apply). Below them:
- **Controls**: mode, channels, temperature, Custom CCT (and which scale), scene (the bulb's and
  your custom scenes) and speed, brightness, brighter/dimmer. Each value opens an editor: the
  Digital Crown moves it one step per detent (1, or 10 K for temperatures, with a haptic tick), −
  and + do the same, and a keypad enters an exact number (its display is also a text field, which
  offers the system's input, a number pad where watchOS provides one).
- **Compose**: a change with its own fade time, sent in one go.
- **Presets**: tap to apply; swipe one, then Edit, to rename it, update it to the current light,
  or delete it.
- **Custom Scenes** to play, **Save Current Light** as a preset, and **Bulb** to switch between the
  iPhone's bulbs.
- Read-back mismatches ("Bulb didn't apply: …") show as on the iPhone.
- While it's in the foreground it asks the iPhone for the state every 4 seconds. Each request wakes the iPhone
  app if needed, which reconnects and re-registers with the bulb for pushes, then forwards changes
  to the watch as they arrive for as long as iOS keeps it awake. (iOS doesn't let it listen in the
  background indefinitely.)

**Complications and Smart Stack** (watch): the bulb's status, a preset (tap to apply; pick from the
suggestions when adding it), and power (tap to switch). They open the app to act, since watch
widgets can't reach the iPhone themselves. watchOS doesn't let apps send UDP (only while streaming audio), so
the watch sends every command to the iPhone app over WatchConnectivity, which talks to the bulb and
replies with its state. The iPhone has to be in Bluetooth or Wi-Fi range of the watch; the iPhone
app doesn't need to be open. The presets and last state are cached on the watch for when it isn't.

Both run on iOS 26 and watchOS 26. Free signing lasts 7 days, so reinstall from Xcode weekly.

### Account-dependent capabilities

`Account.xcconfig` (the project's base configuration) has two switches; set them to what your
developer account allows and rebuild. They pick the entitlements (`Entitlements/`) and set Swift
compilation conditions, so the code that needs them is left out otherwise.

| Switch | Default | What it gives | Needs |
|---|---|---|---|
| `WIZ_APP_GROUPS` | YES | The iPhone widgets, Control Center controls and watch complications (they read the apps' data through the group) | App Groups; free accounts seem to manage, but if Xcode won't sign, set NO and they're left out of the apps |
| `WIZ_ICLOUD` | NO | iCloud sync of presets, custom scenes, CCT scales and bulb names between Mac and iPhone (key-value storage; last change wins per list) | A paid account |

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

[docs/UDP-API.md](docs/UDP-API.md) describes the local API as setPilot uses it: messages and
replies, `setPilot`, live updates, scenes, and the methods the bulb takes over UDP.
