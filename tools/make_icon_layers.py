"""Generates Common/AppIcon.icon (an Icon Composer package): the "Channels" icon.

Five slider tracks with glass knobs, one per bulb channel: red, green, blue, cool white and warm
white, in the same colours as the app's sliders. Red, green and blue are the macOS 26 system
colours, in their light and dark versions for the icon's Default and Dark variants; the whites
are the black-body colours of 6500 K and 2700 K rendered as in the app (CAT02, adapted to
ADAPTING_WHITE). The background is the icon's own fill, light by default and dark in the Dark
appearance, so the system draws the exact macOS shape.

Notes from testing with Xcode 26.6:
- Untagged SVG colours are read as sRGB.
- Adding "color-space-for-untagged-svg-colors" to icon.json crashes actool.
- A layer "fill" gradient in icon.json allows only two colours.

Run from the repository root:
    python3 tools/make_icon_layers.py [adapting white in kelvin, default 4500]
"""
import json
import sys
from pathlib import Path

# As ColourTemperature.defaultAdaptingWhite in the app; override with an argument to experiment:
#   python3 tools/make_icon_layers.py 4800
ADAPTING_WHITE = float(sys.argv[1]) if len(sys.argv) > 1 else 4500

CAT02 = ((0.7328, 0.4296, -0.1624), (-0.7036, 1.6975, 0.0061), (0.0030, 0.0136, 0.9834))
CAT02_INV = ((1.096124, -0.278869, 0.182745), (0.454369, 0.473533, 0.072098), (-0.009628, -0.005698, 1.015326))
D65 = (0.3127 / 0.3290, 1.0, (1 - 0.3127 - 0.3290) / 0.3290)


def _mul(m, v):
    return tuple(sum(m[i][j] * v[j] for j in range(3)) for i in range(3))


def planck_xyz(t):
    """XYZ (Y = 1) of the Planckian locus at t kelvin (Kim et al. 2002)."""
    if t <= 4000:
        x = -0.2661239e9 / t**3 - 0.2343589e6 / t**2 + 0.8776956e3 / t + 0.179910
    else:
        x = -3.0258469e9 / t**3 + 2.1070379e6 / t**2 + 0.2226347e3 / t + 0.240390
    if t <= 2222:
        y = -1.1063814 * x**3 - 1.34811020 * x**2 + 2.18555832 * x - 0.20219683
    elif t <= 4000:
        y = -0.9549476 * x**3 - 1.37418593 * x**2 + 2.09137015 * x - 0.16748867
    else:
        y = 3.0817580 * x**3 - 5.87338670 * x**2 + 3.75112997 * x - 0.37001483
    return (x / y, 1.0, (1 - x - y) / y)


def planck_srgb(t):
    """sRGB of a light at t kelvin for a viewer adapted to ADAPTING_WHITE (CAT02 von Kries),
    max channel normalised. Same model as ColourTemperature.colour(kelvin:) in the app."""
    s, a, w = _mul(CAT02, planck_xyz(t)), _mul(CAT02, planck_xyz(ADAPTING_WHITE)), _mul(CAT02, D65)
    X, Y, Z = _mul(CAT02_INV, tuple(s[i] * w[i] / a[i] for i in range(3)))
    rgb = [3.2404542 * X - 1.5371385 * Y - 0.4985314 * Z,
           -0.9692660 * X + 1.8760108 * Y + 0.0415560 * Z,
           0.0556434 * X - 0.2040259 * Y + 1.0572252 * Z]
    rgb = [max(c, 0) for c in rgb]
    peak = max(rgb)
    enc = lambda c: 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055
    return tuple(round(255 * enc(c / peak)) for c in rgb)



ICON = Path("Common/AppIcon.icon")
HDR = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'

# macOS 26 system colours (NSColor.systemRed/Green/Blue, light appearance), as the app's sliders
RED, GREEN, BLUE = (255, 56, 60), (52, 199, 89), (0, 136, 255)
# ...and their dark-appearance versions, for the icon's Dark variant (as the app's sliders in dark mode)
RED_DARK, GREEN_DARK, BLUE_DARK = (255, 66, 69), (48, 209, 88), (0, 145, 255)
COOL, WARM = planck_srgb(6500), planck_srgb(2700)  # the same in both appearances
CHANNELS = [RED, GREEN, BLUE, COOL, WARM]
CHANNELS_DARK = [RED_DARK, GREEN_DARK, BLUE_DARK, COOL, WARM]
XS = [212, 362, 512, 662, 812]       # track centres on the 1024 canvas
LEVELS = [610, 380, 520, 300, 680]   # knob centres
TOP, BOTTOM, TRACK, KNOB = 220, 804, 26, 68


def hexc(rgb):
    return "#%02x%02x%02x" % tuple(rgb)


def colour(rgb):
    return "extended-srgb:" + ",".join(f"{c / 255:.5f}" for c in rgb) + ",1.00000"


def vertical(top, bottom):
    return {"linear-gradient": [colour(top), colour(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}


def grooves_svg():
    """The empty part of each track, from the top to the knob's centre. Drawn opaque; the layer's
    opacity makes it faint, which (unlike a translucent colour) survives the Tinted appearance's
    white fill."""
    r = TRACK // 2
    return HDR + "".join(
        f'  <rect x="{x - r}" y="{TOP}" width="{TRACK}" height="{y - TOP}" rx="{r}" fill="#8e93a3"/>\n'
        for x, y in zip(XS, LEVELS)) + "</svg>\n"


def fills_svg(channels=CHANNELS):
    """The filled part of each track, from the knob's centre down, in the channel's colour."""
    r = TRACK // 2
    return HDR + "".join(
        f'  <rect x="{x - r}" y="{y}" width="{TRACK}" height="{BOTTOM - y}" rx="{r}" fill="{hexc(c)}"/>\n'
        for x, y, c in zip(XS, LEVELS, channels)) + "</svg>\n"


def knobs_svg(channels=CHANNELS):
    return HDR + "".join(f'  <circle cx="{x}" cy="{y}" r="{KNOB}" fill="{hexc(c)}"/>\n'
                         for x, y, c in zip(XS, LEVELS, channels)) + "</svg>\n"


# In the Tinted appearance (which the Clear style also uses) the system derives brightness from
# each colour, which left the red and blue knobs dim; a uniform fill keeps all five equal (the
# grooves keep their transparency). The knobs are a touch below white so the glass's bright rim
# still shows against them.
TINTED_WHITE = {"appearance": "tinted", "value": {"solid": "extended-gray:1.00000,1.00000"}}
TINTED_KNOBS = {"appearance": "tinted", "value": {"solid": "extended-gray:0.85000,1.00000"}}


def by_appearance(name):
    """The light image, with the dark-colour version in the Dark appearance."""
    return [{"value": f"{name}.svg"}, {"appearance": "dark", "value": f"{name}-dark.svg"}]


def manifest():
    return {
        "fill-specializations": [
            {"value": vertical((246, 246, 249), (218, 221, 228))},
            {"appearance": "dark", "value": vertical((52, 54, 62), (22, 23, 28))},
        ],
        "groups": [
            {"layers": [{"glass": True, "image-name-specializations": by_appearance("knobs"), "name": "knobs",
                         "fill-specializations": [TINTED_KNOBS]}],
             "lighting": "individual",
             "shadow": {"kind": "neutral", "opacity": 0.5},
             # Opaque glass: the tracks run underneath and mustn't show through the knobs.
             "translucency": {"enabled": False, "value": 0}},
            {"layers": [{"glass": False, "image-name-specializations": by_appearance("fills"), "name": "fills",
                         "fill-specializations": [TINTED_WHITE]},
                        {"glass": False, "image-name": "grooves.svg", "name": "grooves", "opacity": 0.35,
                         "fill-specializations": [TINTED_WHITE]}],
             "shadow": {"kind": "none", "opacity": 0.5}},
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }


if __name__ == "__main__":
    assets = ICON / "Assets"
    assets.mkdir(parents=True, exist_ok=True)
    for old in assets.iterdir():
        old.unlink()
    (assets / "grooves.svg").write_text(grooves_svg())
    (assets / "fills.svg").write_text(fills_svg())
    (assets / "knobs.svg").write_text(knobs_svg())
    (assets / "fills-dark.svg").write_text(fills_svg(CHANNELS_DARK))
    (assets / "knobs-dark.svg").write_text(knobs_svg(CHANNELS_DARK))
    (ICON / "icon.json").write_text(json.dumps(manifest(), indent=2).replace('": ', '" : ') + "\n")
    print("wrote", ICON, [hexc(c) for c in CHANNELS])
