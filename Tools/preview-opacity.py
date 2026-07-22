#!/usr/bin/env python3
"""Compare candidate `Palette.settled` values on the live row.

    uv run --with pillow python3 Tools/preview-opacity.py [backdrop.png]

Writes ~/Desktop/agentique-settled.png: one row per candidate, drawn with the real marks,
real session colors and real spacing, at true menu bar scale. `settled` is both the
resting level of a seen mark and the floor of the working pulse. Marks are dimmed by color, not opacity, so
each sits at full opacity in a darker shade — the first at full brightness, the rest at
the row's fraction.

Rows are drawn over `Tools/menubar-backdrop.png`, a screenshot of the real menu bar. That
matters: the bar is a translucent gradient over the wallpaper, not flat black, and a dim
shade reads differently against it than against a dark swatch.
"""
import os
import re
import subprocess
import sys
from PIL import Image, ImageDraw

CANDIDATES = [0.20, 0.30, 0.35, 0.40, 0.50, 0.60]

# MarkRenderer geometry, doubled for a 2x display.
MARK, GAP, GROUP_GAP, PAD = 28, 16, 40, 24
BACKDROP = (28, 28, 30, 255)
LABEL = (150, 150, 155, 255)

APP = "build/Agentique.app/Contents/MacOS/Agentique"


def row_from_dump():
    """(mark key, hex color) per visible workspace, in row order."""
    out = subprocess.run([APP, "--dump"], capture_output=True, text=True).stdout
    marks = []
    for line in out.splitlines()[1:]:
        parts = re.split(r"\s{2,}", line.strip())
        if len(parts) >= 4 and parts[3].startswith("#"):
            marks.append((parts[2], parts[3]))
    return marks


def artwork(key):
    """Vector art is rasterised through AppKit first — PIL reads neither SVG nor PDF."""
    for ext in ("pdf", "svg", "png"):
        path = f"Assets/agents/{key}.{ext}"
        if not os.path.exists(path):
            continue
        if ext != "png":
            os.makedirs("build/raster", exist_ok=True)
            cached = f"build/raster/{key}.png"
            if not os.path.exists(cached) or os.path.getmtime(cached) < os.path.getmtime(path):
                subprocess.run(
                    ["swift", "Tools/rasterize.swift", path, cached, "256"], check=True
                )
            path = cached
        image = Image.open(path).convert("RGBA")
        box = image.split()[3].getbbox()
        return image.crop(box) if box else image
    return None


def dimmed_rgb(hex_color, fraction):
    """Scale brightness toward black, keeping hue — matches CmuxColor.dim."""
    import colorsys
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    r, g, b = colorsys.hsv_to_rgb(h, s, v * fraction)
    return (round(r * 255), round(g * 255), round(b * 255))


def tinted(key, hex_color, fraction):
    art = artwork(key)
    if art is None:
        return None
    width = max(1, round(MARK * art.width / art.height))
    scaled = art.resize((width, MARK), Image.LANCZOS)
    # Dim by color at full opacity, so the mark stays a true shade of itself.
    layer = Image.new("RGBA", scaled.size, dimmed_rgb(hex_color, fraction) + (255,))
    layer.putalpha(scaled.split()[3])
    return layer


def backdrop_strip(path, width):
    """A clean menu bar gradient, taken from a screenshot with icons in it.

    Per row, the median across x lands on background as long as icons cover less than
    half the width — which removes them without needing a clean plate."""
    source = Image.open(path).convert("RGB")
    height = source.height
    pixels = source.load()
    strip = Image.new("RGBA", (width, height))
    out = strip.load()
    for y in range(height):
        row = sorted(pixels[x, y] for x in range(source.width))
        r, g, b = row[len(row) // 2]
        for x in range(width):
            out[x, y] = (r, g, b, 255)
    return strip


def main():
    marks = row_from_dump()
    if not marks:
        print("no marks; is cmux running?")
        return

    backdrop_path = sys.argv[1] if len(sys.argv) > 1 else "Tools/menubar-backdrop.png"

    rows = []
    for settled in CANDIDATES:
        images, previous_color = [], None
        for index, (key, color) in enumerate(marks):
            
            alpha = settled if index else 1.0
            image = tinted(key, color, alpha)
            if image is None:
                continue
            gap = 0 if index == 0 else (GAP if color == previous_color else GROUP_GAP)
            images.append((gap, image))
            previous_color = color
        rows.append((settled, images))

    gutter = 60
    row_width = PAD * 2 + max(sum(g + i.width for g, i in r[1]) for r in rows)
    strip = backdrop_strip(backdrop_path, row_width)
    bar_height = strip.height

    out = Image.new("RGBA", (gutter + row_width, len(rows) * bar_height), BACKDROP)
    draw = ImageDraw.Draw(out)

    y = 0
    for settled, images in rows:
        out.alpha_composite(strip, (gutter, y))
        draw.text((16, y + bar_height // 2 - 6), f"{int(settled * 100):>3}%", fill=LABEL)
        x = gutter + PAD
        # Marks sit on the bar's optical centre, as the status item does.
        mark_y = y + (bar_height - MARK) // 2 - 2
        for gap, image in images:
            x += gap
            out.alpha_composite(image, (x, mark_y))
            x += image.width
        y += bar_height

    target = os.path.expanduser("~/Desktop/agentique-settled.png")
    out.save(target)
    print(f"wrote {target}")


if __name__ == "__main__":
    main()
