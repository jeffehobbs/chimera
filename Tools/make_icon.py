#!/usr/bin/env python3
"""Draw Chimera's icon: two projects' waveforms braided into one.

    python3 Tools/make_icon.py           # writes Sources/Mac/Assets.xcassets

Two inks over a dark ground, alternating column by column — the same gesture the
Byte Weave strategy performs on the file itself. Riso-ish: the inks overlap and
the overlap is its own color rather than one hiding the other.
"""
import json, math, pathlib, subprocess, sys
from PIL import Image, ImageDraw

S = 2048                      # drawn big, downsampled for free antialiasing
GROUND = (22, 20, 19, 255)
INK_A  = (232, 85, 45)        # warm
INK_B  = (63, 182, 200)       # cool
OVERLAP = (247, 233, 120)     # where both inks land

def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m

def comb(size, seed, phase, offset, count=11):
    """A column of bars whose heights trace a waveform — one project's shape.

    `offset` shifts this comb half a period sideways so the two of them
    interleave column by column. The bars are wider than half the period, so
    neighbors overlap by a sliver and the overlap prints as its own ink.
    """
    layer = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(layer)
    margin = size * 0.13
    span = size - margin * 2
    period = span / count            # one bar from each comb per period
    w = period * 0.62                # > half a period, so the seams overlap
    for i in range(count):
        # Two summed sines, so the two combs never share a silhouette.
        t = i / (count - 1)
        h = (0.26 + 0.36 * abs(math.sin(t * math.pi * 1.7 + phase))
                 + 0.24 * abs(math.sin(t * math.pi * 4.3 + phase * seed)))
        h = min(h, 0.92)
        bar = span * h
        x0 = margin + i * period + offset * period * 0.5
        y0 = size / 2 - bar / 2
        d.rounded_rectangle([x0, y0, x0 + w, y0 + bar], radius=w * 0.42, fill=255)
    return layer

def build():
    a = comb(S, 1.0, 0.0, offset=0)
    b = comb(S, 2.3, 2.4, offset=1)

    img = Image.new("RGBA", (S, S), GROUND)
    px = img.load()
    ap, bp = a.load(), b.load()
    for y in range(S):
        for x in range(S):
            av, bv = ap[x, y], bp[x, y]
            if not av and not bv:
                continue
            if av and bv:
                c = OVERLAP
            elif av:
                c = INK_A
            else:
                c = INK_B
            k = max(av, bv) / 255
            base = px[x, y]
            px[x, y] = tuple(int(base[i] + (c[i] - base[i]) * k) for i in range(3)) + (255,)

    img.putalpha(rounded_mask(S, int(S * 0.2237)))
    return img

def write_iconset(img, out_dir):
    iconset = out_dir / "AppIcon.appiconset"
    iconset.mkdir(parents=True, exist_ok=True)
    entries = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            img.resize((px, px), Image.LANCZOS).save(iconset / name)
            entries.append({"idiom": "mac", "size": f"{size}x{size}",
                            "scale": f"{scale}x", "filename": name})
    (iconset / "Contents.json").write_text(json.dumps(
        {"images": entries, "info": {"version": 1, "author": "xcode"}}, indent=2))
    (out_dir / "Contents.json").write_text(json.dumps(
        {"info": {"version": 1, "author": "xcode"}}, indent=2))
    return iconset

if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parents[1]
    img = build()
    out = write_iconset(img, root / "Sources/Mac/Assets.xcassets")
    img.resize((512, 512), Image.LANCZOS).save(root / "Tools/icon-preview.png")
    print("wrote", out)
