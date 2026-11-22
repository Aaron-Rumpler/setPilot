# setPilot

A small native app (SwiftUI) for controlling a single WiZ RGB bulb, mainly for experimenting with
raw RGBCW values: on the Mac, with an iPhone app and an Apple Watch app alongside. It's named after
`setPilot`, the bulb's command for setting the light.

setPilot was written entirely by Claude, Anthropic's AI model, working in Claude Code.

setPilot is an independent project, not affiliated with or endorsed by Signify or WiZ. WiZ is a
trademark of Signify.

## Features

- Sliders (with exact-value fields and steppers) for **R, G, B, cool white, warm white** and
  **dimming**, sent as raw `setPilot` values. The last payload sent is shown, syntax-highlighted,
  with a button to copy it as JSON.
- Every change is read back from the bulb; values it ignored or adjusted are flagged.
- Each `setPilot` carries only what changed: the colour (all five channels, the temperature or the
  scene), dimming or speed. The firmware ignores some valid parameters when they're combined with
  others, and this doesn't undo changes made meanwhile by other apps.
- The sliders never switch the bulb on or off: a `setPilot` to a bulb that's off carries
  `"state": false` (one without `state` switches it on). Only the power switch (and Shortcuts'
  on/off), applying a preset, Compose with Power set, a light show, the console (its `setPilot`
  unless Don't switch on is set, its `setState`, and Raw messages as typed), the widgets' and Control Center's power and presets, and playing a scene
  from the watch's Custom Scenes list change it.
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
- **Shortcuts** (Mac too): apply a preset, switch on or off, set the brightness, brighter or dimmer,
  set a colour, colour temperature (on a CCT scale or the bulb's own), scene or custom scene, switch
  to another of your bulbs, Set Light (any of a colour, temperature or scene, the brightness and the
  power, in one change, as Compose sends), and Get Light State (each part usable in later actions,
  and as JSON); each change can have a fade of its own (otherwise the controls' fade);
  from the Shortcuts app, Spotlight and Siri. A change counts as done once the bulb has answered and
  read back as asked; otherwise the action fails with why (not answering, refused, not applied).
  Colour, temperature and scene actions leave the power as it is unless Switch On is set.
- **setpilot:// links** (Mac and iPhone), for launchers and automation tools, with x-callback-url:
  `setpilot://power?on=toggle`, `setpilot://scene?name=Ocean&speed=150`,
  `setpilot://x-callback-url/get?x-success=…` (the state as JSON, in `state`, without the bulb's MAC
  and address; callbacks to `file:` and other non-app schemes aren't opened). The actions:
  `get`, `power` (`on=true|false|toggle`), `brightness` (`level`), `brighter`/`dimmer` (`step`),
  `colour` (`r g b c w`), `temperature` (`kelvin`, `scale` a CCT scale's name or `bulb`), `scene`
  (`name`, `speed`), `custom-scene` (`name`), `speed` (`value`), `preset` (`name`) and `switch` (`bulb`),
  with `on=1` to switch the bulb on too; `set` (any of `rgb=r,g,b[,c,w]`, `temp`+`scale`,
  `scene`, `custom`, with `speed`, `brightness`, `power=on|off`) for several at once; `fade=ms` on
  any change; and `list` (`what=presets|scenes|custom-scenes|scales|bulbs`, given to x-success as
  `items`). x-error gets `errorCode` and `errorMessage`. Only what the
  app's controls do: no raw bulb methods, as web pages can open these links too.
- **Command-line tool** (Mac): `setpilot get`, `on`, `off`, `toggle`, `brightness 40`, `brighter`,
  `colour 255 80 0`, `temp 2700 --scale bulb`, `scene Ocean --speed 150`, `custom <name>`,
  `preset <name>`, `switch <bulb>`, `set --scene Ocean --brightness 40 --on --fade 2000` (several at
  once, in one change), `list presets` and `watch` (the state, one line each time it changes);
  `--json` for JSON (JSON Lines for `watch`), `--on` to switch the bulb on too, `--fade <ms>` for
  any change. It asks the
  app (launching it in the background if needed), with an exit code for each kind of failure (see
  `setpilot --help`). It's inside the app: link it onto your PATH, e.g.
  `ln -s /Applications/setPilot.app/Contents/Helpers/setpilot /usr/local/bin/setpilot`. It needs App
  Groups and a development team, signed with a development certificate rather than "Sign to Run
  Locally" (set `DEVELOPMENT_TEAM` in `Account.xcconfig`; see below).
- **Import from the WiZ app** (Settings on the Mac, Bulb & Settings on iPhone): paste the WiZ app's
  home export link (or the JSON it opens) to name your bulbs by room ("Room - Name", or just the room
  for a room's only light, optionally with the home's name first) and give them the home's signing
  key. A list shows what would change before anything does; bulbs not used here yet keep their name
  and key for when they are.
- **Console** (Window › Console, ⌥⌘K, or Console… on the Last Command panel; on iPhone, Bulb &
  Settings › Console, with the log on its own page): send any method with any params. Known
  methods (the 36 firmware 1.38.0 takes over UDP; it refuses the rest) are in a menu with params to
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
- Retries one-off commands (up to 5 sends over about 4 s, with backoff).
- **Round numbers**: sliders (and the watch's Digital Crown) snap to round steps, and the steppers
  and − and + step to the next one: 5 for dimming and other percentages, 50 K for temperatures, 32
  for 0–255 channels, 10 for speed, 100 ms for times (50 ms for the light show's bulb delay). Snapping can be turned off in Settings.
  Finer: hold a slider's knob still for a moment before dragging (Mac and iPhone; a haptic tick
  says it's on), or on the Mac hold Option while dragging, using the arrow keys or clicking a
  stepper. Tapping a value on iPhone or the watch opens a number pad, where − and + (and the
  Crown) step by 1; temperatures and times also have ±10 (on the watch the default, with a button
  to switch to 1s). Keyboard: arrow keys step a focused slider, ⌘R syncs.
- **Presets**: save the light as it is (colour, temperature, scene or custom scene, with its
  brightness) and apply it with one click, from the window or the menu bar panel. Applying a preset
  switches the bulb on. Right-click a preset to rename, update, move or delete it.
- **Custom scenes** (Window › Custom Scenes, or Edit Scenes… next to the scene picker): up to 12
  steps, each with a colour (RGBCW, a temperature, or dark), a level, how long it holds and how
  long it fades into the next, and optionally a random variation of those times. A scene can start
  on any step, and use the bulb's slow or quick fixed timings instead of its steps' own. They're
  played inline (`setPilot` with `sceneId` 300 and an `elm` definition), so nothing stored on the
  bulb is touched; the bulb can't read definitions back, so they're kept in setPilot. They appear in the scene picker after the bulb's own.
- **Compose a change** (the Compose button in the Light panel's heading in the window, by the
  power switch in the menu bar panel, or Compose on the Light section on iPhone): the Light controls switch to a draft that
  isn't sent until you press Send (⌘Return on the Mac). Prepare a new state (any of colour,
  brightness and power) and send it as one `setPilot`; the controls then go back to live. The draft
  is kept if you switch back without sending. Its fade is the fade time setting (shown, if there
  is one), none (no `trans`), or a value just for this change, say 10 s. It starts from the bulb's
  current state, and From Bulb starts it again. A scene can have a speed too, which goes in a
  `setPilot` of its own just after (the firmware ignores speed alongside anything else).
- **Signed requests**, for newer firmware that refuses unsigned changes: set a bulb's signing key
  (the home's `udp_signing_key`, from the WiZ app's export for local integration) with the key
  button in the Device panel on the Mac, or Signing in Bulb & Settings on iPhone, and every request
  to it is signed as pywizlight signs them. Keys are kept on each device.
- **Light Show** (Window › Light Show, ⌥⌘L, or Light Show… on the Last Command panel; on iPhone,
  Light Show on the main screen): plays an audio or video file and sends the bulb the states in a
  light show file (`.lights.json`: setPilot params at times in the media) as it plays. A **Bulb
  delay** slider sends every cue that much early, to make up for the bulb's lag; seeking sends the
  state at the new place first; and stopping (or the end) can put the light back as it was. The format is in
  [docs/LIGHT-SHOW.md](docs/LIGHT-SHOW.md).
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
- **Fade time** (Settings; off by default, so no `trans` is sent): the `trans`, in milliseconds,
  that the controls' Fade and Compose offer as the default; the bulb's own fades (from
  `getUserConfig`) are shown alongside. Turning off always uses the bulb's fade-out.

## iPhone and Apple Watch

The iPhone app has the same controls, presets and custom scenes (its own, kept on the iPhone), the
same Shortcuts actions as the Mac (above), and setpilot:// links. Through the Shortcuts app those
reach Siri, the Action button, and Control Center and the Lock Screen (a Shortcuts control).
Brighter and dimmer step from wherever the bulb is: read first, then sent as a level, so a resend
can't step twice. The watch has Shortcuts actions of its own, going through the iPhone: apply a
preset, switch on or off, brighter or dimmer, and the light's state, for Siri on the watch, its
Action button and the Smart Stack. It has the console
too (Bulb & Settings › Console).

The iPhone app doesn't search the network: broadcasting needs Apple's multicast entitlement (paid
accounts only), and probing every address on a network isn't acceptable on networks you don't own.
Enter the bulb's IP address or DNS name; a DNS name keeps working if the address changes.

The iPhone remembers the bulbs you've used (Bulb & Settings › Your Bulbs) to switch between.

**Widgets and controls** (iPhone, and the Mac on macOS 26):
- **Presets:** tap a preset. It has power, and brighter/dimmer on the larger sizes. Edit Widget picks
  which presets it shows, in order.
- **Bulb:** a small widget with the bulb's state, brighter, dimmer and power, for the Home Screen,
  StandBy and the Mac's desktop.
- **Lock Screen** (iPhone): a bulb status, with a power toggle on the rectangular size.
- **Control Center:** controls for power, a preset of your choice, brighter and dimmer. On iPhone
  they also work from the Action button; on the Mac, from the menu bar.

On iPhone their actions run in the app in the background, on its connection to the bulb. If the
system runs them in the widget extension instead, the extension sends the request itself. On the
Mac they always run in the extension. That needs App Groups and a development team, as the
command-line tool does.

The watch has complications (status, a preset, power) for watch faces and the Smart Stack, and
Control Center controls (power, a preset, brighter, dimmer), which also work from the Smart Stack
and the Action button. A tap opens the watch app, which asks the iPhone: watch widgets can't do it
themselves.

The Watch app's main screen is power and the presets (tap to apply). Below them:
- **Controls**: mode, channels, temperature, Custom CCT (and which scale), scene (the bulb's and
  your custom scenes) and speed, brightness, brighter/dimmer. Each value opens an editor: the
  Digital Crown moves it one round step per detent (as the sliders snap, or 1 with snapping off on
  the iPhone; with a haptic tick), − and + go to the next round number, and a keypad enters an
  exact number (its display is also a text field, which
  offers the system's input, a number pad where watchOS provides one). Then the controls' fade,
  and the last command sent with its status.
- **Compose**: a change with its own fade time (and a scene's speed), sent in one go, with a
  preview of what it sends.
- Changes from the Crown go to the bulb as you turn: the first at once, then the latest each time
  the iPhone answers the one before, so nothing queues up behind you.
- **Presets**: tap to apply; swipe one, then Edit, to rename it, update it to the current light,
  move it, or delete it.
- **Custom Scenes** to play, with speed and brightness for the one playing; **Save Current Light**
  as a preset; and **Bulb** to switch between the iPhone's bulbs (swipe one to name it), with the
  bulb's details and its device info.
- Read-back mismatches ("Bulb didn't apply: …") show as on the iPhone.
- While it's in the foreground it asks the iPhone for the state every 4 seconds. Each request wakes the iPhone
  app if needed, which reconnects and re-registers with the bulb for pushes (and reads its state
  again if it may have missed some while suspended), then forwards changes
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
| `WIZ_APP_GROUPS` | YES | The widgets and Control Center controls on iPhone and Mac, the watch complications and controls (they read the apps' data through the group), and the Mac's command-line tool (it reaches the app through the group container) | App Groups; free accounts seem to manage, but if Xcode won't sign, set NO and they're left out of the apps. On the Mac the group is Team-ID-prefixed, so the Mac widgets and the command-line tool also need a development team (an ad-hoc build has no Team ID, so no container) |
| `WIZ_ICLOUD` | NO | iCloud sync of presets, custom scenes, CCT scales and bulb names between Mac and iPhone (key-value storage; last change wins per list) | A paid account |

Not supported: storing scenes on the bulb (`setExtendedLightMode`: its 20 slots can't be read
back, so writing one could overwrite a scene the WiZ app stored), changing the bulb's own settings
(`setUserConfig`, except from the console), multiple bulbs, Rhythm and sync-box scenes (shown when the bulb is in one, but not settable),
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
| `Common/` | all the apps and widget extensions, the command-line tool and the tests: light types, colour maths, the watch messages, the build info, the icon |
| `WidgetShared/` | the iPhone app and the iPhone and Mac widget extensions: sending to the bulb from a widget, the widget intents |
| `setPilotWidgets/` | the iPhone and Mac widgets and Control Center controls (targets "setPilot Widgets" and "setPilot Mac Widgets") |
| `setPilotWatchWidgets/` | the watch complications and Control Center controls |
| `Scripting/` | Mac and iPhone apps and the command-line tool: what scripting can ask for, and setpilot:// parsing |
| `setpilotCLI/` | the command-line tool (target "setpilot CLI", built into the Mac app's `Contents/Helpers`) |
| `Tests/` | unit tests (target "setPilotTests", with Common and Scripting), run in CI with `xctest` |

Each app records the commit it was built from (from `git describe`, with `-dirty` for uncommitted
changes) and shows it in Settings and the About panel (on the watch, on the Bulb screen).

To run on your iPhone and watch, choose the "setPilot iOS" scheme, pick your (free or paid) team for
both the iOS and Watch targets under Signing & Capabilities, and run.

Pushes to any branch and pull requests are built on GitHub Actions (macOS 26): the Mac app, and the
iPhone app with the watch app (unsigned, to check it compiles). The Mac app is uploaded as an
artifact. It's ad-hoc signed, so after downloading it you'll need to clear the
quarantine flag or approve it in System Settings › Privacy & Security:

```bash
xattr -dr com.apple.quarantine setPilot.app
```

Pushing a version tag (`v1.0.0`, say) runs the Release workflow, which puts the Mac app on a GitHub
release as a DMG. With the `DEVELOPER_ID_P12`, `DEVELOPER_ID_PASSWORD` and `DEVELOPMENT_TEAM`
repository secrets (a paid account's Developer ID certificate) it's signed, and with
`NOTARY_APPLE_ID` and `NOTARY_PASSWORD` too, notarised; without them it's the same ad-hoc build.
The CI also builds and runs the unit tests.

## Notes

- Local Network access is required. If it was denied, turn it on in System Settings › Privacy &
  Security › Local Network.
- Live updates need port 38900 free (e.g. not used by Home Assistant on the same Mac). A bulb chosen
  by DNS name is resolved to its IPv4 address for them.
- R, G, B, C and W don't correspond directly to LED drive: the firmware remaps them (with a white
  LED lit they act more like proportions), and dimming is applied separately.
- Scene `speed` only takes effect when sent on its own (a firmware bug), so the app sends it as a
  separate `setPilot`.
- Setting R, G, B, C and W all to 0 makes the bulb return an error rather than turn off; use the
  power switch.

## Protocol

JSON over UDP port 38899, e.g.:

```json
{"method":"setPilot","params":{"r":255,"g":0,"b":0,"c":0,"w":128}}
```

[docs/UDP-API.md](docs/UDP-API.md) describes the local API as the app uses it: messages and
replies, `setPilot`, live updates, scenes, and the methods the bulb takes over UDP.

## Licence

setPilot is released under the [MIT License](LICENSE).
