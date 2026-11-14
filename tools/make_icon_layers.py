#!/usr/bin/env python3
"""Generates the layer artwork for setPilot/AppIcon.icon (an Icon Composer package).

The background is the icon's own fill (see icon.json), so the system draws the exact macOS
shape; only the disc (a Liquid Glass layer) and its glow are images. The disc is shaded with
the same black-body colours as the app's Kelvin track: 2200 K bottom-left to 6500 K top-right.

Requires Pillow. Run from the repository root: python3 tools/make_icon_layers.py
"""
import math
from pathlib import Path

from PIL import Image, ImageFilter

OUT = Path("setPilot/AppIcon.icon/Assets")
CANVAS = 1024          # Icon Composer canvas for iOS/macOS
SS = 4                 # supersampling for smooth edges
RADIUS = 300           # disc radius on the 1024 canvas


def planck_srgb(t):
    """sRGB of the Planckian locus at t kelvin (Kim et al. 2002), max channel normalised."""
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
    X, Y, Z = x / y, 1.0, (1 - x - y) / y
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


def disc():
    s, r = CANVAS * SS, RADIUS * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    px = img.load()
    c = s / 2
    cache = {}
    for yy in range(int(c - r), int(c + r) + 1):
        for xx in range(int(c - r), int(c + r) + 1):
            dx, dy = xx - c, yy - c
            if dx * dx + dy * dy <= r * r:
                f = min(max((dx - dy) / (2 * r * math.sqrt(2)) + 0.5, 0), 1)
                k = round(f * 255)
                if k not in cache:
                    cache[k] = planck_srgb(mired_lerp(k / 255))
                px[xx, yy] = cache[k] + (255,)
    return img.resize((CANVAS, CANVAS), Image.LANCZOS)


def glow(d):
    g = d.resize((CANVAS, CANVAS)).filter(ImageFilter.GaussianBlur(CANVAS * 0.07))
    g.putalpha(g.getchannel("A").point(lambda a: int(a * 0.8)))
    return g


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    d = disc()
    d.save(OUT / "disc.png")
    glow(d).save(OUT / "glow.png")
    print("wrote", OUT / "disc.png", OUT / "glow.png")
