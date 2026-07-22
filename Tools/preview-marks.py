#!/usr/bin/env python3
"""Preview every mark in Assets/agents at true menu bar size.

    uv run --with pillow python3 Tools/preview-marks.py

Writes ~/Desktop/agentique-marks.png: each mark magnified, with the actual-size render
directly beneath it. The small one is what the menu bar really draws — judge legibility
there, not on the magnified copy.
"""
import glob
import os
import subprocess
import sys
from PIL import Image, ImageDraw

# MarkRenderer.markSize is 14pt, drawn on a 2x display.
MARK = 28
ZOOM = 7
PAD = 30
GAP = 44
TINT = (233, 176, 95, 255)  # cmux Amber as it renders in dark mode
BACKDROP = (28, 28, 30, 255)


def load(path):
    if not path.endswith(".png"):
        # Vector art goes through AppKit; PIL reads neither SVG nor PDF.
        os.makedirs("build/raster", exist_ok=True)
        cached = f"build/raster/{os.path.splitext(os.path.basename(path))[0]}.png"
        subprocess.run(["swift", "Tools/rasterize.swift", path, cached, "256"], check=True)
        path = cached
    image = Image.open(path).convert("RGBA")
    box = image.split()[3].getbbox()
    if box:
        image = image.crop(box)  # the app trims transparent margins too
    width = max(1, round(MARK * image.width / image.height))
    scaled = image.resize((width, MARK), Image.LANCZOS)
    tinted = Image.new("RGBA", scaled.size, TINT)
    tinted.putalpha(scaled.split()[3])
    return tinted


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else "Assets/agents"
    paths = sorted(
        p for ext in ("png", "pdf", "svg") for p in glob.glob(f"{source}/*.{ext}")
    )
    if not paths:
        print(f"no artwork in {source}")
        return

    marks = [(os.path.splitext(os.path.basename(p))[0], load(p)) for p in paths]
    width = sum(m.width * ZOOM for _, m in marks) + GAP * (len(marks) - 1) + PAD * 2
    out = Image.new("RGBA", (width, MARK * ZOOM + PAD * 2 + MARK + 30), BACKDROP)
    draw = ImageDraw.Draw(out)

    x = PAD
    for name, mark in marks:
        out.alpha_composite(mark.resize((mark.width * ZOOM, MARK * ZOOM), Image.NEAREST), (x, PAD))
        out.alpha_composite(mark, (x, PAD + MARK * ZOOM + 14))
        aspect = mark.width / MARK
        draw.text(
            (x, PAD + MARK * ZOOM + 14 + MARK + 6),
            f"{name}  {mark.width}x{MARK}px  aspect {aspect:.2f}"
            + ("  OVER 1.8 - will shrink" if aspect > 1.8 else ""),
            fill=(150, 150, 155, 255),
        )
        x += mark.width * ZOOM + GAP

    target = os.path.expanduser("~/Desktop/agentique-marks.png")
    out.save(target)
    print(f"wrote {target}")


if __name__ == "__main__":
    main()
