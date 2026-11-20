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
- 1 to 12 `steps`, each exactly 13 numbers (see below).

The other keys of `elm`:

| Key | Meaning |
|---|---|
| `modifier` | Required, below 108 (or the scene is rejected). On this bulb only two values change anything: **4** replaces every step's hold and fade with 1500 ms each, and **5** with 400 and 500 ms. Every other value, 1 included, keeps each step's own timing |
| `support` | A bit mask of the light types the scene is for; it must include this bulb's (odd numbers do; 17 works) or the scene doesn't play |
| `initStep` | The step to start on, from 0 (the default) to one less than the number of steps |
| `direction`, `gradient`, `rand` | Accepted (`direction` must be 0 or 1) but have no effect on these scenes |

Each step:

| # | Meaning |
|---|---|
| 0 | mode: 0 colour, anything else temperature |
| 1–5 | red, green, blue, **warm**, **cool** (0–255; colour steps) |
| 6 | kelvin (temperature steps) |
| 7 | level, 1–100 % (see below) |
| 8 | hold, ms |
| 9 | fade into the next step, ms |
| 10 | timing jitter (see below); 0 for none |
| 11, 12 | passed through by the bulb, with no known effect on these scenes; send 0 |

**Level isn't a brightness control for most colours.** It scales the step's channels, but the bulb
then scales many colours back up to full strength: mixes such as red with warm white, magenta, or
equal red, green and blue look the same at most levels and only dim once the level is very low.
Temperatures below 2700 K are mixed from red and warm white, so they behave the same way. A single
channel (red alone, say, or only warm or cool white, as at 2700 K and above) dims with the level
as you'd expect. To dim a whole scene, use `dimming`, which can be sent while it plays.

**Jitter** varies a step's hold and fade at random each time it plays. It's a bit field:

| Bits | Value | Choices |
|---|---|---|
| 0–1 | how often | 0: every time, 1: 10 %, 2: 50 %, 3: 90 % of the time |
| 2–4 | hold, up to ± | 0: none, 1: 10 %, 2: 25 %, 3: 75 %, 4 or 7: 100 %, 5–6: none |
| 5–7 | fade, up to ± | 0: none, 1: 10 %, 2: 25 %, 3: 50 %, 4: 75 %, 5: 100 %, 6–7: none |

So `176` (fade 5, hold 4, every time) is the most jitter. The amount is random up to the limit, in
either direction, and never takes a time below 20 ms.

A colour step with all five channels at 0 should play as dark, which makes a blink in a scene
(unconfirmed).

Nothing is stored on the bulb; it can't report the steps back, so an app has to keep its own copy.

## Live updates

To hear about changes made elsewhere (the WiZ app, a remote, a schedule), register with the bulb:

```json
{"method": "registration", "params": {"phoneMac": "a1b2c3d4e5f6", "register": true, "phoneIp": "192.168.1.20"}}
```

The bulb then sends `syncPilot` messages to **port 38900** at `phoneIp` whenever its state changes,
with the same keys as `getPilot`. Registration lapses, so repeat it (the app re-registers every
20 s). A firewall can block the pushes even when registration succeeds.

## The bulb's settings: setUserConfig

`getUserConfig` reads the bulb's own settings and `setUserConfig` changes them. setPilot only
offers it in the console: a mistake here changes how the bulb behaves for every app, and some of
it only shows at the next power-on.

```json
{"method": "setUserConfig", "params": {"userConfigTs": 0, "fadeIn": 450, "fadeOut": 500}}
```

`userConfigTs` is required. It versions the settings: a
non-zero value equal to the stored one changes nothing, any other value applies the request and
stores it, and 0 always applies without storing. Every other key is optional, and only the keys
sent change:

| Key | Meaning | Takes effect |
|---|---|---|
| `fadeIn`, `fadeOut` | the fade times used without `trans`, ms | at once |
| `dftDim` | brightness at power-on, % | next power-on |
| `startupMode` | power-on behaviour: `"default"`, `"wizclick"` or `"lastStatus"` | next power-on |
| `po` | after a power cut, go back to the state before it | next power-on |
| `poRhy` | after a power cut, carry on with the Rhythm too | next power-on |
| `minDimming` | a minimum brightness, %, on bulbs that support one | at once |
| `dim2WarmPoints` | the curve the Dim-to-warm scene follows: exactly five `[kelvin, dimming]` pairs (kelvin is still held to the bulb's range) | at once |
| `autoUpd` | automatic firmware updates | at once |

Unknown keys are ignored. A missing `userConfigTs` or a bad value (four `dim2WarmPoints` pairs,
say) is refused as an invalid parameter.

## Signed requests

Some newer firmware answers with `"env": "pro"` and an `hmac` key, and wants writes signed:
unsigned, `setPilot` fails with "Invalid parameter"; with a bad signature, with code `-32605`
("Security error"). Reads still work unsigned. This is as pywizlight implements it.

The key is the home's `udp_signing_key` (32 hex digits), from the WiZ app's export of the home
for local integration. To sign a request, add `sigTs` (the current Unix time in seconds) to
`params`, then add `"env": "pro"` and `hmac`: the Base64 HMAC-SHA256 of the compact `params`
JSON (no spaces), keyed with the hex-decoded key.

```json
{"method": "setPilot", "env": "pro", "params": {"state": true, "sigTs": 1790441723}, "hmac": "vARMv4JpVsxYabcBovABd25ISBzYT8+71v0CUtpU1sg="}
```

(Key `00112233445566778899aabbccddeeff`.) The bulb refuses a `sigTs` more than about a minute
old, so the clock has to be right. setPilot signs everything it sends to a bulb that has a key set,
except the console's raw messages, which go as typed.

## What the bulb takes over UDP

Firmware 1.38.0 accepts these 36 methods over the local network:

- **Reads:** getPilot, getDevInfo, getSystemConfig, getModelConfig, getUserConfig, getCctTable,
  getColorProfile, getPowerProfile, getPower, getTime, getEffect, getTelemetry, getIotpOTAStatus,
  getFavs, getScenario, getSensor, getSensorConfig, getLuxSensing, getAcc, getWifiBeaconing,
  getWifiProcessing, getWifiProcessingData. Reads for features a bulb doesn't have may answer with
  an error ("Invalid parameter" for some on this bulb).
- **Actions:** registration, pulse (a brief brightness blink), syncBroadcastPilot, syncAmbience,
  syncAccEvt, syncScnrEvt, camSelfTest, setTest.
- **Writes:** setPilot, setState, setEffect, setExtendedLightMode (stores a scene in one of the
  bulb's slots, which may hold the WiZ app's scenes), setSystemConfig (home, environment and
  region), setUserConfig (the bulb's own settings; see above).

Its other methods, including reboot, factory reset and the other configuration setters (model
configuration, Wi-Fi), aren't available over UDP.

The app's console lists these methods with starting params, and sends any other name as typed.
