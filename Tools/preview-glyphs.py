#!/usr/bin/env python3
"""Preview every glyph in Assets/agents at true menu bar size.

    uv run --with pillow python3 Tools/preview-glyphs.py

Writes ~/Desktop/agentique-glyphs.png: each glyph magnified, with the actual-size render
directly beneath it. The small one is what the menu bar really draws—judge legibility
there, not on the magnified copy.
"""
import glob
import os
import subprocess
import sys
from PIL import Image, ImageDraw

# GlyphRenderer.glyphSize is 16pt, drawn on a 2x display.
GLYPH = 32
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
    width = max(1, round(GLYPH * image.width / image.height))
    scaled = image.resize((width, GLYPH), Image.LANCZOS)
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

    glyphs = [(os.path.splitext(os.path.basename(p))[0], load(p)) for p in paths]
    width = sum(m.width * ZOOM for _, m in glyphs) + GAP * (len(glyphs) - 1) + PAD * 2
    out = Image.new("RGBA", (width, GLYPH * ZOOM + PAD * 2 + GLYPH + 30), BACKDROP)
    draw = ImageDraw.Draw(out)

    x = PAD
    for name, glyph in glyphs:
        out.alpha_composite(glyph.resize((glyph.width * ZOOM, GLYPH * ZOOM), Image.NEAREST), (x, PAD))
        out.alpha_composite(glyph, (x, PAD + GLYPH * ZOOM + 14))
        aspect = glyph.width / GLYPH
        draw.text(
            (x, PAD + GLYPH * ZOOM + 14 + GLYPH + 6),
            f"{name}  {glyph.width}x{GLYPH}px  aspect {aspect:.2f}"
            + ("  OVER 1.8 - will shrink" if aspect > 1.8 else ""),
            fill=(150, 150, 155, 255),
        )
        x += glyph.width * ZOOM + GAP

    target = os.path.expanduser("~/Desktop/agentique-glyphs.png")
    out.save(target)
    print(f"wrote {target}")


if __name__ == "__main__":
    main()
