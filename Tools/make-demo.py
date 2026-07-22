#!/usr/bin/env python3
"""Render the README media into docs/.

    uv run --with pillow python3 Tools/make-demo.py

Writes docs/pulse.gif (the row over one full pulse cycle) and docs/states.png (the three
treatments, labelled).

The row is synthetic rather than read from a live cmux: the README should show the same
picture on every machine, and a real row would leak whichever projects happened to be
open. Everything else is real — the artwork in Assets/agents, the geometry from
MarkRenderer, the brightness fractions from Palette, and a screenshot of an actual menu
bar as the backdrop.
"""
import colorsys
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFont

# MarkRenderer geometry in points, rendered at SCALE. The README shows these at half
# their pixel width, which is sharp on a 2x display and about twice true menu bar size —
# native size is honest but too small to read on a project page.
SCALE = 4
MARK, GAP, PAD = 16 * SCALE, 10 * SCALE, 12 * SCALE

# Palette, from Sources/AgentState.swift.
FULL, SETTLED, PULSE_FLOOR = 1.0, 0.70, 0.35
PULSE_PERIOD = 1.4

# Tokyo Night accents, the colors cmux assigns to workspaces.
BLUE, GREEN, PURPLE, ROSE = "#7DCFFF", "#9ECE6A", "#BB9AF7", "#F7768E"

# (artwork, color, state) per mark. Two projects are mid-turn, one finished while you
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
BACKDROP = "Tools/menubar-backdrop.png"
# The screenshot's bar proper: below this is its bottom border and the desktop under it.
BACKDROP_WIDTH, BAR_HEIGHT = 406, 59
OUT = "docs"

INK = (235, 235, 240, 255)
MUTED = (145, 145, 152, 255)
PAGE = (22, 22, 24, 255)


def font(size, bold=False):
    for path in (
        "/System/Library/Fonts/SFNS.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


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
                subprocess.run(["swift", "Tools/rasterize.swift", path, cached, "256"], check=True)
            path = cached
        image = Image.open(path).convert("RGBA")
        box = image.split()[3].getbbox()
        return image.crop(box) if box else image
    raise SystemExit(f"no artwork for {key}")


def dimmed(hex_color, fraction):
    """Scale brightness toward black, keeping hue — matches CmuxColor.dim."""
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    r, g, b = colorsys.hsv_to_rgb(h, s, v * fraction)
    return (round(r * 255), round(g * 255), round(b * 255), 255)


def mark(key, hex_color, fraction):
    """One mark: the artwork's alpha, flooded with the session color at `fraction`."""
    art = artwork(key)
    width = max(1, round(MARK * art.width / art.height))
    scaled = art.resize((width, MARK), Image.LANCZOS)
    layer = Image.new("RGBA", scaled.size, dimmed(hex_color, fraction))
    layer.putalpha(scaled.split()[3])
    return layer


def fraction_for(state, phase):
    """Brightness for a state at a point in the pulse cycle, 0..1."""
    if state == "working":
        return PULSE_FLOOR + (FULL - PULSE_FLOOR) * phase
    return FULL if state == "unseen" else SETTLED


def bar(width):
    """A clean menu bar gradient, taken from a screenshot that has icons in it.

    Per row the median across x lands on background as long as icons cover less than
    half the width, which removes them without needing a clean plate. Rows where they
    cover more than half leave a streak of icon color, so the column of medians is then
    median-filtered down its length: the bar is a smooth vertical gradient, and any row
    that disagrees with its neighbours is an artifact rather than a feature.
    """
    source = Image.open(BACKDROP).convert("RGB").crop((0, 0, BACKDROP_WIDTH, BAR_HEIGHT))
    pixels = source.load()
    rows = []
    for y in range(source.height):
        column = sorted(pixels[x, y] for x in range(source.width))
        rows.append(column[len(column) // 2])

    smoothed = [
        tuple(sorted(row[c] for row in rows[max(0, y - 2):y + 3])[len(rows[max(0, y - 2):y + 3]) // 2]
              for c in range(3))
        for y in range(len(rows))
    ]

    # The bar is uniform across x, so it is built as a one-pixel column, resampled to the
    # target height, then stretched sideways.
    column = Image.new("RGB", (1, len(smoothed)))
    column.putdata(smoothed)
    column = column.resize((1, round(len(smoothed) * SCALE / 2)), Image.LANCZOS)
    return column.resize((width, column.height), Image.NEAREST).convert("RGBA")


def row_width(row):
    widths = [mark(key, color, FULL).width for key, color, _ in row]
    return PAD * 2 + sum(widths) + GAP * (len(row) - 1)


def render_row(row, phase, width=None):
    """The status item as it would be drawn, on a strip of real menu bar."""
    width = width or row_width(row)
    strip = bar(width)
    x = PAD
    for key, color, state in row:
        image = mark(key, color, fraction_for(state, phase))
        # Marks sit on the bar's optical centre, as the status item does.
        strip.alpha_composite(image, (x, (strip.height - MARK) // 2 - 2))
        x += image.width + GAP
    return strip


def save_gif(frames, path, duration):
    """One shared palette across every frame, so the gradient does not shimmer."""
    master = Image.new("RGB", (frames[0].width, frames[0].height * len(frames)))
    for index, frame in enumerate(frames):
        master.paste(frame.convert("RGB"), (0, index * frames[0].height))
    palette = master.quantize(colors=255, method=Image.MEDIANCUT)
    indexed = [frame.convert("RGB").quantize(palette=palette, dither=Image.NONE) for frame in frames]
    indexed[0].save(
        path,
        save_all=True,
        append_images=indexed[1:],
        duration=duration,
        loop=0,
        optimize=True,
    )


def make_pulse():
    count = round(PULSE_PERIOD * FPS)
    frames = [
        render_row(ROW, phase=0.5 + 0.5 * math.sin(2 * math.pi * i / count))
        for i in range(count)
    ]
    save_gif(frames, f"{OUT}/pulse.gif", duration=round(1000 / FPS))


def make_states():
    """One labelled row per treatment, at the size the menu bar actually draws.

    A still cannot show motion, and a working mark at the top of its swing is exactly as
    bright as a finished one — so the pulsing case is drawn as a trail down its cycle,
    which separates the two the way the animation does on screen.
    """
    rows = [
        ("Mid-turn", "pulses between 35% and full brightness", BLUE, "working", [1.0, 0.68, 0.35]),
        ("Finished, not yet seen", "holds at full brightness until you visit it", GREEN, "unseen", [1.0]),
        ("Finished, seen", "settles to 70% and stays there", PURPLE, "seen", [1.0]),
    ]

    title_font, body_font = font(10 * SCALE), font(8 * SCALE)
    swatch_width = PAD * 2 + MARK * 3 + GAP * 2
    gutter, line_height = 12 * SCALE, 32 * SCALE

    # Size the canvas to the longest label rather than a guess, so nothing clips when
    # SCALE or the wording changes.
    probe = ImageDraw.Draw(Image.new("RGB", (1, 1)))
    text_width = max(
        max(probe.textlength(title, font=title_font), probe.textlength(detail, font=body_font))
        for title, detail, *_ in rows
    )
    width = swatch_width + gutter + round(text_width) + 12 * SCALE

    out = Image.new("RGBA", (width, line_height * len(rows)), PAGE)
    draw = ImageDraw.Draw(out)

    for index, (title, detail, color, state, phases) in enumerate(rows):
        y = index * line_height
        strip = bar(swatch_width)
        x = PAD
        for phase in phases:
            image = mark("claude", color, fraction_for(state, phase))
            strip.alpha_composite(image, (x, (strip.height - MARK) // 2 - 2))
            x += image.width + GAP
        out.alpha_composite(strip, (0, y + (line_height - strip.height) // 2))

        text_x = swatch_width + gutter
        draw.text((text_x, y + 8 * SCALE), title, font=title_font, fill=INK)
        draw.text((text_x, y + 19 * SCALE), detail, font=body_font, fill=MUTED)

    out.convert("RGB").save(f"{OUT}/states.png")


def main():
    os.makedirs(OUT, exist_ok=True)
    make_pulse()
    make_states()
    for name in ("pulse.gif", "states.png"):
        path = f"{OUT}/{name}"
        print(f"wrote {path} ({os.path.getsize(path) // 1024}KB)")


if __name__ == "__main__":
    main()
