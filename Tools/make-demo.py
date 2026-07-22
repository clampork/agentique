#!/usr/bin/env python3
"""Render the README animation into docs/.

    uv run --with pillow python3 Tools/make-demo.py

Writes docs/pulse.png, an APNG of the row over one full pulse cycle. The background is
transparent so the glyphs sit on either GitHub theme, and APNG rather than GIF because a
GIF pixel is either fully opaque or fully clear, which fringes antialiased edges.

The row is synthetic rather than read from a live cmux: the README should look the same
on every machine, and a real row would leak whichever projects happened to be open. The
artwork, the geometry and the brightness fractions are the real ones.
"""
import colorsys
import math
import os
import subprocess

from PIL import Image

# GlyphRenderer geometry in points, rendered at SCALE. The README shows this at half its
# pixel width: sharp on a 2x display, and about twice true menu bar size, which native
# size is too small to read on a project page.
SCALE = 4
GLYPH, GAP = 16 * SCALE, 10 * SCALE

# Palette, from Sources/AgentState.swift.
FULL, SETTLED, PULSE_FLOOR = 1.0, 0.70, 0.35
PULSE_PERIOD = 1.4

# Tokyo Night accents, the colors cmux assigns to workspaces.
BLUE, GREEN, PURPLE, ROSE = "#7DCFFF", "#9ECE6A", "#BB9AF7", "#F7768E"

# (artwork, color, state) per glyph. Two projects are mid-turn, one finished while you
# were looking elsewhere, the rest are settled.
ROW = [
    ("claude", BLUE, "working"),
    ("codex", BLUE, "seen"),
    ("claude", GREEN, "unseen"),
    ("claude", PURPLE, "seen"),
    ("codex", ROSE, "working"),
    ("claude", ROSE, "seen"),
]

FPS = 20
OUT = "docs"


def artwork(key):
    """Vector art is rasterised through AppKit first: PIL reads neither SVG nor PDF."""
    for ext in ("pdf", "svg", "png"):
        path = f"Assets/agents/{key}.{ext}"
        if not os.path.exists(path):
            continue
        if ext != "png":
            os.makedirs("build/raster", exist_ok=True)
            cached = f"build/raster/{key}.png"
            if not os.path.exists(cached) or os.path.getmtime(cached) < os.path.getmtime(path):
                subprocess.run(["swift", "Tools/rasterize.swift", path, cached, "256"], check=True)
            path = cached
        image = Image.open(path).convert("RGBA")
        box = image.split()[3].getbbox()
        return image.crop(box) if box else image
    raise SystemExit(f"no artwork for {key}")


def dimmed(hex_color, fraction):
    """Scale brightness toward black, keeping hue, matching CmuxColor.dim."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    r, g, b = colorsys.hsv_to_rgb(h, s, v * fraction)
    return (round(r * 255), round(g * 255), round(b * 255), 255)


def glyph(key, hex_color, fraction):
    """One glyph: the artwork's alpha, flooded with the session color at `fraction`."""
    art = artwork(key)
    scaled = art.resize((max(1, round(GLYPH * art.width / art.height)), GLYPH), Image.LANCZOS)
    layer = Image.new("RGBA", scaled.size, dimmed(hex_color, fraction))
    layer.putalpha(scaled.split()[3])
    return layer


def fraction_for(state, phase):
    """Brightness for a state at a point in the pulse cycle, 0..1."""
    if state == "working":
        return PULSE_FLOOR + (FULL - PULSE_FLOOR) * phase
    return FULL if state == "unseen" else SETTLED


def frame(phase):
    glyphs = [glyph(key, color, fraction_for(state, phase)) for key, color, state in ROW]
    width = sum(m.width for m in glyphs) + GAP * (len(glyphs) - 1)
    canvas = Image.new("RGBA", (width, GLYPH), (0, 0, 0, 0))
    x = 0
    for image in glyphs:
        canvas.alpha_composite(image, (x, 0))
        x += image.width + GAP
    return canvas


def main():
    os.makedirs(OUT, exist_ok=True)
    # Forced odd: over an even count a sine hits every value twice, and Pillow's APNG
    # writer mangles the frame sequence when it tries to fold those duplicates away.
    count = round(PULSE_PERIOD * FPS) | 1
    frames = [frame(0.5 + 0.5 * math.sin(2 * math.pi * i / count)) for i in range(count)]

    path = f"{OUT}/pulse.png"
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=round(PULSE_PERIOD * 1000 / count),
        loop=0,
        # blend_op SOURCE writes each frame's pixels over the last, alpha included, so a
        # glyph fading down does not leave its brighter self showing underneath. Pillow
        # emits a malformed sequence if asked to dispose to background as well.
        disposal=0,
        blend=0,
    )
    print(f"wrote {path} ({frames[0].width}x{frames[0].height}, {os.path.getsize(path) // 1024}KB)")


if __name__ == "__main__":
    main()
