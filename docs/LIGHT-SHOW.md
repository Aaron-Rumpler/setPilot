# Light show files

setPilot's Light Show player plays an audio or video file and sends the bulb a `setPilot` at set
times in it. The times and states come from a light show file: JSON, usually named after the media
with `.lights.json` on the end (`Song.m4a` and `Song.lights.json`).

```json
{
  "setPilotLightShow": 1,
  "title": "Example",
  "media": "Song.m4a",
  "cues": [
    {"t": 0,          "pilot": {"temp": 2700, "dimming": 40, "trans": 2000}, "label": "Intro"},
    {"t": 12.5,       "pilot": {"r": 255, "g": 0, "b": 40, "c": 0, "w": 0, "dimming": 100, "trans": 0}},
    {"t": "1:03.250", "pilot": {"dimming": 20, "trans": 800}, "label": "Verse 2"},
    {"t": "1:10",     "pilot": {"sceneId": 4}},
    {"t": "1:10.4",   "pilot": {"speed": 180}}
  ]
}
```

| Key | Meaning |
|---|---|
| `setPilotLightShow` | The format version: 1. Required |
| `title`, `media` | Optional. `title` is shown in the player; `media` is the file it was made for, mentioned if other media is open |
| `cues` | The cues, in any order (they're sorted by time) |

Each cue:

| Key | Meaning |
|---|---|
| `t` | When, in the media's time: seconds (`72.25`), or `"m:ss.sss"` / `"h:mm:ss.sss"` |
| `pilot` | The `setPilot` params to send, as the bulb takes them (see [UDP-API.md](UDP-API.md)) |
| `label` | Optional: shown in the cue list |

`pilot` is sent as it is, with nothing added. Worth knowing (see UDP-API.md for the details):

- A `setPilot` without `state` switches the bulb on, so a show switches the bulb on with its first
  cue. `{"state": false}` switches it off, always with the bulb's own fade-out.
- A colour is `r` `g` `b` `c` `w` (send all five for a colour of its own: missing ones aren't
  zeroed), `temp`, or `sceneId`. All five channels at 0 is an error, not black: for "dark", use a
  low `dimming` with a dim colour, or `state: false`.
- `dimming` is 10–100 (the bulb's minimum may be higher). It can be sent on its own.
- `trans` is the fade into this state, in ms. Without it the bulb uses its own fade (often ~0.5 s),
  so give `"trans": 0` for a hard cut.
- `speed` only takes effect in a `setPilot` of its own, so give it its own cue just after the
  scene's. A speed cue while the show has the bulb off is held (on its own it would switch the
  bulb on), and sent once a cue switches it back on, unless that cue brings a new colour, scene or
  speed of its own.
- `r` `g` `b` `c` `w` given only in part change just those channels; the bulb keeps the others.
  A `temp` or `sceneId` replaces the colour altogether.
- Keep cues at least ~80 ms apart. The bulb handles about ten changes a second; much faster and
  it drops or queues them.

## Timing

The bulb takes a moment to show a change (the network, and the fade starting). The player's
**Bulb delay** slider sends every cue that much early, so it lands on time: dial it in until a
hard cut on screen and on the bulb coincide. It can go below zero for when the picture or sound
is the late one (Bluetooth headphones, a TV's processing).

Seeking, or starting part way through, first sends the state the show would be in at that point
(the cues so far, combined), then carries on from there. The player can put the light back as it
was when the show is stopped.
