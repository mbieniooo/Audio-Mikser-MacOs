#!/usr/bin/env python3
"""Renders Resources/Mikser.icns: a macOS squircle with three mixer sliders.
Usage: scripts/make-icon.py            (needs Pillow: python3 -m pip install Pillow)
Regenerate after changing the design; scripts/build.sh copies the .icns into the app bundle."""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(__file__), "..")
S = 1024               # master size; every icon size is a downscale of this render
SUPER = 4              # supersampling factor for smooth edges

def squircle_mask(size, radius_ratio=0.225):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * radius_ratio), fill=255)
    return m

def render():
    n = S * SUPER
    inset = int(n * 0.10)                       # macOS icons leave a transparent margin
    body = n - 2 * inset
    # vertical gradient: deep graphite to slightly lighter graphite
    grad = Image.new("RGB", (1, body))
    for y in range(body):
        t = y / (body - 1)
        grad.putpixel((0, y), (int(38 + 18 * (1 - t)), int(40 + 20 * (1 - t)), int(48 + 24 * (1 - t))))
    bg = grad.resize((body, body))
    d = ImageDraw.Draw(bg)
    # three slider tracks with knobs at different levels
    track_h = int(body * 0.055)
    knob_r = int(body * 0.075)
    left, right = int(body * 0.18), int(body * 0.82)
    rows = [(0.30, 0.72), (0.50, 0.42), (0.70, 0.60)]     # (y ratio, knob position ratio)
    accent = (255, 159, 10)                                # macOS system orange
    for yr, pos in rows:
        y = int(body * yr)
        d.rounded_rectangle([left, y - track_h // 2, right, y + track_h // 2], radius=track_h // 2, fill=(92, 96, 108))
        kx = left + int((right - left) * pos)
        d.rounded_rectangle([left, y - track_h // 2, kx, y + track_h // 2], radius=track_h // 2, fill=accent)
        d.ellipse([kx - knob_r, y - knob_r, kx + knob_r, y + knob_r], fill=(245, 245, 247))
        d.ellipse([kx - knob_r, y - knob_r, kx + knob_r, y + knob_r], outline=(0, 0, 0, 40), width=max(1, knob_r // 12))
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(bg, (inset, inset), squircle_mask(body))
    return out.resize((S, S), Image.LANCZOS)

def main():
    master = render()
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "Mikser.iconset")
        os.mkdir(iconset)
        for px in (16, 32, 128, 256, 512):
            master.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{px}x{px}.png"))
            master.resize((px * 2, px * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{px}x{px}@2x.png"))
        dest = os.path.join(ROOT, "Resources", "Mikser.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", dest], check=True)
        master.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "Resources", "icon-preview.png"))
        print("wrote", os.path.relpath(dest))

if __name__ == "__main__":
    sys.exit(main())
