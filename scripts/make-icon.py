#!/usr/bin/env python3
"""Generate AgentNotch.icns from a drawn 1024px master.

Dark rounded-square icon with the MacBook notch and three green "agent" motes —
matching the app's own agent-swarm language. Pure PIL, no external assets.
"""
import os
import subprocess
import sys
from PIL import Image, ImageDraw

OUT = os.path.dirname(os.path.abspath(__file__))
S = 1024


def rounded(size, radius, fill):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=fill)
    return img


def master():
    img = rounded(S, int(S * 0.225), (18, 20, 24, 255))  # charcoal squircle
    d = ImageDraw.Draw(img)

    # top notch (a black pill hanging from the top edge)
    nw, nh = int(S * 0.34), int(S * 0.11)
    nx = (S - nw) // 2
    d.rounded_rectangle([nx, -nh, nx + nw, nh], radius=nh, fill=(0, 0, 0, 255))

    # three agent motes on a gentle diagonal — soft glow + bright core, green.
    # Glow is drawn as stacked translucent rings on a separate layer so it reads
    # as light, not a solid disc.
    green = (74, 222, 128)
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx = S / 2
    motes = [(cx - S * 0.23, S * 0.44), (cx, S * 0.55), (cx + S * 0.23, S * 0.66)]
    for (x, y) in motes:
        for k in range(6, 0, -1):
            r = S * 0.02 * k
            gd.ellipse([x - r, y - r, x + r, y + r], fill=(74, 222, 128, 16))
    img = Image.alpha_composite(img, glow)
    d = ImageDraw.Draw(img)
    for (x, y) in motes:
        core = int(S * 0.038)
        d.ellipse([x - core, y - core, x + core, y + core], fill=green + (255,))

    return img


def main():
    img = master()
    png = os.path.join(OUT, "icon-1024.png")
    img.save(png)

    iconset = os.path.join(OUT, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
             (256, 1), (256, 2), (512, 1), (512, 2)]
    for size, scale in specs:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))

    icns = os.path.join(OUT, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("wrote", icns)


if __name__ == "__main__":
    main()
