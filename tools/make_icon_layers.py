#!/usr/bin/env python3
"""Generates the disc artwork for setPilot/AppIcon.icon (an Icon Composer package).

The background is the icon's own fill (see icon.json), so the system draws the exact macOS shape.
The disc is a vector Liquid Glass layer: a circle whose gradient follows the black-body colours
of the app's Kelvin track, 2200 K (bottom left) to 6500 K (top right), evenly in mireds.

Notes from testing with Xcode 26.6:
- Untagged SVG colours are read as sRGB, matching the app's colours.
- Adding "color-space-for-untagged-svg-colors" to icon.json crashes actool.
- A layer "fill" gradient in icon.json allows only two colours, which can't follow the curve.

Run from the repository root: python3 tools/make_icon_layers.py [adapting white in kelvin, default 4500]
"""
import math
from pathlib import Path

OUT = Path("setPilot/AppIcon.icon/Assets/disc.svg")
CENTRE, RADIUS, STOPS = 512, 300, 11  # on Icon Composer's 1024 × 1024 canvas


import sys

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


def mired_lerp(f):
    """Temperature at fraction f between 2200 K and 6500 K, even in mireds (as the app's slider)."""
    lo, hi = 1e6 / 2200, 1e6 / 6500
    return 1e6 / (lo + (hi - lo) * f)


def svg():
    o = RADIUS / math.sqrt(2)  # gradient runs corner to corner across the disc's diagonal
    stops = "\n".join(
        '      <stop offset="%.1f" stop-color="#%02x%02x%02x"/>' % ((i / (STOPS - 1),) + planck_srgb(mired_lerp(i / (STOPS - 1))))
        for i in range(STOPS))
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="blackbody" gradientUnits="userSpaceOnUse" x1="{CENTRE - o:.1f}" y1="{CENTRE + o:.1f}" x2="{CENTRE + o:.1f}" y2="{CENTRE - o:.1f}">
{stops}
    </linearGradient>
  </defs>
  <circle cx="{CENTRE}" cy="{CENTRE}" r="{RADIUS}" fill="url(#blackbody)"/>
</svg>
'''


if __name__ == "__main__":
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(svg())
    print("wrote", OUT)
