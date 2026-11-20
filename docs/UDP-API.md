# WiZ local UDP API

How a WiZ bulb is controlled over the local network, as the setPilot app uses it. Written against an RGB
bulb (module ESP25_SHRGB_01) on firmware 1.38.0; other models and firmware may differ. It covers the
local API only: the WiZ app's account, cloud and setup aren't involved.

## Messages

Requests are JSON sent by UDP to the bulb's **port 38899**, one message per datagram:

```json
{"method": "getPilot", "params": {}}
```

The bulb answers the sender with the same `method` and either a `result` or an `error`:

```json
{"method": "getPilot", "env": "pro", "result": {"mac": "a8bb50000000", "rssi": -60, "state": true, "sceneId": 0, "temp": 2700, "dimming": 60}}
```

```json
{"method": "getTelemetry", "env": "pro", "error": {"code": -32602, "message": "Invalid parameter"}}
```

`-32601` ("Method not found") means the bulb doesn't take that method, at least not over UDP.

UDP can drop messages, so one-off requests are worth resending until a reply with the same
method arrives. The app follows pywizlight: up to six sends, 0.75 s apart at first, doubling to
at most 3 s. Rapid changes (dragging a slider) aren't resent; the next one supersedes them.

## Finding bulbs

Send `registration` with `"register": false` to the broadcast address of the local network:

```json
{"method": "registration", "params": {"phoneMac": "AAAAAAAAAAAA", "register": false, "phoneIp": "1.2.3.4", "id": "1"}}
```

Each bulb answers with its MAC (`result.mac`). The MAC and IP in the request are placeholders: with
`register` false the bulb doesn't use them.

## Reading the light: getPilot

`getPilot` returns the current state:

| Key | Meaning |
|---|---|
| `state` | on (`true`) or off |
| `dimming` | brightness, 10–100 % |
| `r` `g` `b` `c` `w` | red, green, blue, cool white, warm white, 0–255 (when set as colour) |
| `temp` | colour temperature in kelvin (when set as one) |
| `sceneId` | the scene playing, or 0 |
| `speed` | the scene's speed |
| `schdPsetId` | present while a Rhythm (schedule) is running |
| `mac`, `rssi` | the bulb's MAC and Wi-Fi signal strength |

It reports what was last set, so it can't show how the bulb remaps a colour internally.

## Setting the light: setPilot

`setPilot` takes any of:

| Key | Meaning |
|---|---|
| `r` `g` `b` `c` `w` | channels, 0–255. Not LED drive: with a white channel lit, the colours act more like proportions |
| `temp` | kelvin; clamped to the bulb's range (2200–6500 K here; `getModelConfig`'s `cctRange`) |
| `sceneId` | a built-in scene (1–40 on this bulb), or a custom one (see Scenes) |
| `speed` | scene speed, 10–200 |
| `dimming` | 10–100 (the bulb's minimum is `getModelConfig`'s `minDimLevel`) |
| `dimDelta` | a relative change in brightness, added to the current level |
| `state` | `false` keeps or switches the bulb off; `true` switches it on |
| `trans` | fade time for this change, in ms |

A colour, a temperature and a scene are alternatives: send one of them.

Things worth knowing:

- **A `setPilot` without `state` switches the bulb on.** To change the light while it's off, include
  `"state": false`; the change shows when it's next switched on.
- **`speed` is ignored when sent with anything else**, so send it in a `setPilot` of its own, after
  the scene.
- Some valid parameters are ignored in combination with others, so it's safest to send only what
  changed, and to read the state back afterwards. The bulb replies `{"success": true}` even when it
  hasn't applied everything.
- Setting all five channels to 0 returns an error rather than turning the bulb off.
- Every change fades. Without `trans`, the bulb uses its own fade times (`getUserConfig`'s `fadeIn`
  and `fadeOut`). Switching off always uses `fadeOut`, whatever `trans` says.

`setState` (`{"state": true}` or `false`) only switches the bulb on or off.

## Scenes

`sceneId` 1–40 are the built-in scenes (Ocean, Romance, Sunset, … Dim-to-warm). The bulb also
plays a scene sent with the request, which is how the app's custom scenes work:

```json
{"method": "setPilot", "params": {"sceneId": 300, "elm": {"modifier": 1, "support": 17, "steps": [
  [0, 255, 60, 0, 0, 0, 0, 100, 2000, 2000, 0, 0, 0],
  [1, 0, 0, 0, 0, 0, 2700, 100, 2000, 2000, 0, 0, 0]
]}}}
```

- `sceneId` must be 266 or more: 256–265 are the bulb's stored custom scenes, which would play instead.
- `modifier` 1 keeps each step's own timing; `support` must be odd (17 works) or the scene doesn't play.
- 1 to 12 `steps`, each 13 numbers: mode (0 colour, 1 temperature), red, green, blue, **warm**,
  **cool**, kelvin, level (1–100 %, on top of `dimming`), hold (ms), fade into the next step (ms),
  then three zeros.

Nothing is stored on the bulb; it can't report the steps back, so an app has to keep its own copy.

## Live updates

To hear about changes made elsewhere (the WiZ app, a remote, a schedule), register with the bulb:

```json
{"method": "registration", "params": {"phoneMac": "a1b2c3d4e5f6", "register": true, "phoneIp": "192.168.1.20"}}
```

The bulb then sends `syncPilot` messages to **port 38900** at `phoneIp` whenever its state changes,
with the same keys as `getPilot`. Registration lapses, so repeat it (the app re-registers every
20 s). A firewall can block the pushes even when registration succeeds.

## What the bulb takes over UDP

Firmware 1.38.0 accepts these 35 methods over the local network:

- **Reads:** getPilot, getDevInfo, getSystemConfig, getModelConfig, getUserConfig, getCctTable,
  getColorProfile, getPowerProfile, getPower, getTime, getEffect, getTelemetry, getIotpOTAStatus,
  getFavs, getScenario, getSensor, getSensorConfig, getLuxSensing, getAcc, getWifiBeaconing,
  getWifiProcessing, getWifiProcessingData. Reads for features a bulb doesn't have may answer with
  an error ("Invalid parameter" for some on this bulb).
- **Actions:** registration, pulse (a brief brightness blink), syncBroadcastPilot, syncAmbience,
  syncAccEvt, syncScnrEvt, camSelfTest, setTest.
- **Writes:** setPilot, setState, setEffect, setExtendedLightMode (stores a scene in one of the
  bulb's slots, which may hold the WiZ app's scenes), setSystemConfig (home, environment and region).

Its other methods, including reboot, factory reset and the configuration setters (user settings,
model configuration, Wi-Fi), aren't available over UDP.

The app's console lists these methods with starting params, and sends any other name as typed.
