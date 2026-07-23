#!/usr/bin/env python3
"""Render the README animations into docs/.

    uv run --with pillow python3 Tools/make-demo.py

Writes two APNGs:

  docs/pulse.png  the glyph row over one full pulse cycle, on a transparent background so
                  it sits on either GitHub theme
  docs/click.png  a mock of cmux under the menu bar, showing a click on a finished agent's
                  glyph landing in that Workspace

Both are synthetic. The README should look the same on every machine, a real row would
leak whichever projects happened to be open, and the mock needs no cmux running to
regenerate. The artwork, geometry and brightness fractions are the real ones; the
Workspace names are invented.

APNG rather than GIF because a GIF pixel is either fully opaque or fully clear, which
fringes the antialiased edges of the transparent row.
"""
import colorsys
import math
import os
import subprocess

from PIL import Image, ImageDraw, ImageFont

# GlyphRenderer geometry in points, rendered at SCALE. The README shows the row at half
# its pixel width: sharp on a 2x display, and about twice true menu bar size, which
# native size is too small to read on a project page.
SCALE = 4
GLYPH, GAP = 16 * SCALE, 10 * SCALE
# Breathing room above and below the row. Larger than the real status item's inset, which
# would crop tight enough to look cramped standing alone on a page.
PAD_Y = 7 * SCALE

# Palette, from Sources/AgentState.swift.
FULL, SETTLED, PULSE_FLOOR = 1.0, 0.70, 0.35
PULSE_PERIOD = 1.4

# Tokyo Night accents, the colors cmux assigns to Workspaces.
BLUE, GREEN, PURPLE, ROSE, ORANGE = "#7DCFFF", "#9ECE6A", "#BB9AF7", "#F7768E", "#FF9E64"

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


# ---------------------------------------------------------------- shared glyph drawing

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


def glyph(key, hex_color, fraction, size):
    """One glyph: the artwork's alpha, flooded with the session color at `fraction`."""
    art = artwork(key)
    scaled = art.resize((max(1, round(size * art.width / art.height)), size), Image.LANCZOS)
    layer = Image.new("RGBA", scaled.size, dimmed(hex_color, fraction))
    layer.putalpha(scaled.split()[3])
    return layer


def fraction_for(state, phase):
    """Brightness for a state at a point in the pulse cycle, 0..1."""
    if state == "working":
        return PULSE_FLOOR + (FULL - PULSE_FLOOR) * phase
    return FULL if state == "unseen" else SETTLED


def save_apng(frames, path, duration):
    frames[0].save(
        path,
        save_all=True,
        append_images=frames[1:],
        duration=duration,
        loop=0,
        # blend_op SOURCE writes each frame's pixels over the last, alpha included, so a
        # glyph fading down does not leave its brighter self showing underneath. Pillow
        # emits a malformed sequence if asked to dispose to background as well.
        disposal=0,
        blend=0,
    )
    print(f"wrote {path} ({frames[0].width}x{frames[0].height}, {os.path.getsize(path) // 1024}KB)")


# ------------------------------------------------------------------------- the row only

def row_frame(phase, size=GLYPH, gap=GAP, pad_y=PAD_Y):
    glyphs = [glyph(key, color, fraction_for(state, phase), size) for key, color, state in ROW]
    width = sum(g.width for g in glyphs) + gap * (len(glyphs) - 1)
    canvas = Image.new("RGBA", (width, size + pad_y * 2), (0, 0, 0, 0))
    x = 0
    for image in glyphs:
        canvas.alpha_composite(image, (x, pad_y))
        x += image.width + gap
    return canvas


def make_pulse():
    # Forced odd: over an even count a sine hits every value twice, and Pillow's APNG
    # writer mangles the frame sequence when it tries to fold those duplicates away.
    count = round(PULSE_PERIOD * FPS) | 1
    frames = [row_frame(0.5 + 0.5 * math.sin(2 * math.pi * i / count)) for i in range(count)]
    save_apng(frames, f"{OUT}/pulse.png", round(PULSE_PERIOD * 1000 / count))


# ------------------------------------------------------------------------- the cmux mock

# 1pt = MOCK px, so the mock renders at 2x and is shown at half width.
MOCK = 2

# Tokyo Night, the theme cmux ships with.
BG = (26, 27, 38, 255)
SIDEBAR = (22, 22, 30, 255)
TITLEBAR = (31, 35, 53, 255)
SELECTED = (40, 52, 87, 255)
TEXT = (192, 202, 245, 255)
MUTED = (86, 95, 137, 255)
BAR = (28, 28, 32, 255)
PAGE = (13, 17, 23, 0)

# Sidebar contents, in row order. Names are invented, and every one is somewhere an agent
# would plausibly be running.
#
# Ungrouped Workspaces come first on purpose: every row shares one indent level, so a
# Workspace listed below a group header would otherwise read as belonging to it.
# (label, color, group). A group of None means the Workspace sits on its own.
TREE = [
    ("docs", PURPLE, None),
    ("infra", ROSE, None),
    ("vault", ORANGE, None),
    ("web", BLUE, "Storefront"),
    ("checkout", BLUE, "Storefront"),
    ("api", GREEN, "Platform"),
    ("billing", GREEN, "Platform"),
]

# The menu bar row for the mock, in the same order. A different mix of agents and colors
# from ROW above, so the two README images do not look like one screenshot used twice.
MOCK_ROW = [
    ("codex", PURPLE, "seen"),
    ("claude", ROSE, "seen"),
    ("claude", ORANGE, "seen"),
    ("claude", BLUE, "seen"),
    ("codex", BLUE, "unseen"),      # checkout: finished while you were elsewhere
    ("claude", GREEN, "working"),   # api: what you are watching
    ("codex", GREEN, "seen"),
]

WATCHING, FINISHED = 5, 4

# Terminal body per Workspace, keyed by row index.
TRANSCRIPTS = {
    WATCHING: [("muted", "$ claude"),
               ("text", "› add rate limiting to /v1/search"),
               ("muted", "  edited api/search.go, api/limit.go"),
               ("run", "  working…")],
    FINISHED: [("muted", "$ claude"),
               ("text", "› fix the coupon rounding bug"),
               ("muted", "  edited checkout/total.ts"),
               ("done", "  done, 3 files changed")],
}


def font(size, mono=False):
    path = "/System/Library/Fonts/Menlo.ttc" if mono else "/System/Library/Fonts/SFNS.ttf"
    return ImageFont.truetype(path, size) if os.path.exists(path) else ImageFont.load_default()


def cursor(draw, x, y, click):
    """A pointer, with a ring at the moment of the click."""
    if click > 0:
        radius = 5 * MOCK + click * 13 * MOCK
        # Fades on a curve rather than linearly, so the ring stays legible most of the
        # way out instead of vanishing in the first frame or two.
        alpha = int(230 * (1 - click) ** 0.6)
        draw.ellipse(
            [x - radius, y - radius, x + radius, y + radius],
            outline=(255, 255, 255, alpha), width=2 * MOCK,
        )
    arrow = [(x, y), (x, y + 15 * MOCK), (x + 4 * MOCK, y + 11 * MOCK),
             (x + 7 * MOCK, y + 17 * MOCK), (x + 10 * MOCK, y + 15 * MOCK),
             (x + 7 * MOCK, y + 9 * MOCK), (x + 11 * MOCK, y + 9 * MOCK)]
    draw.polygon(arrow, fill=(255, 255, 255, 255), outline=(0, 0, 0, 180))


ROW_H, HEADER_H, GROUP_LEAD = 20 * MOCK, 15 * MOCK, 10 * MOCK


def sidebar_rows(top):
    """Top y for every Workspace row, plus (label, y) for each group header, and the y
    the list ends at.

    Rows all sit at one indent, so hierarchy is carried by the header's typography
    rather than by pushing members to the right.
    """
    rows, headers = [], []
    y = top
    seen = set()
    for _, _, group in TREE:
        if group and group not in seen:
            seen.add(group)
            y += GROUP_LEAD
            headers.append((group, y))
            y += HEADER_H
        rows.append(y)
        y += ROW_H
    return rows, headers, y


def mock_frame(phase, selected, cursor_xy, click):
    """One frame of the cmux mock: menu bar on top, cmux window below."""
    bar_h, win_y = 24 * MOCK, 32 * MOCK
    # Height follows the sidebar rather than a guess, so adding a Workspace cannot crop
    # the list or leave a band of dead space under it.
    rows, headers, list_end = sidebar_rows(win_y + 36 * MOCK)
    width = 460 * MOCK
    height = list_end + 22 * MOCK
    canvas = Image.new("RGBA", (width, height), PAGE)
    draw = ImageDraw.Draw(canvas)

    # Menu bar, with the glyph row sitting where a status item would. Visiting a
    # Workspace settles a finished glyph, but a mid-turn one keeps pulsing.
    draw.rectangle([0, 0, width, bar_h], fill=BAR)
    size, gap = 12 * MOCK, 7 * MOCK
    states = [(key, color, "seen" if i == selected and state == "unseen" else state)
              for i, (key, color, state) in enumerate(MOCK_ROW)]
    glyphs = [glyph(key, color, fraction_for(state, phase), size) for key, color, state in states]
    row_w = sum(g.width for g in glyphs) + gap * (len(glyphs) - 1)
    x = width - row_w - 16 * MOCK
    origins = []
    for image in glyphs:
        origins.append(x)
        canvas.alpha_composite(image, (x, (bar_h - size) // 2))
        x += image.width + gap

    # Window.
    win = [10 * MOCK, win_y, width - 10 * MOCK, height - 10 * MOCK]
    draw.rounded_rectangle(win, radius=8 * MOCK, fill=BG)
    draw.rounded_rectangle([win[0], win[1], win[2], win[1] + 24 * MOCK], radius=8 * MOCK, fill=TITLEBAR)
    draw.rectangle([win[0], win[1] + 16 * MOCK, win[2], win[1] + 24 * MOCK], fill=TITLEBAR)
    for i, dot in enumerate([(255, 95, 87), (255, 189, 46), (39, 201, 63)]):
        cx, cy = win[0] + (14 + i * 15) * MOCK, win[1] + 12 * MOCK
        draw.ellipse([cx - 4 * MOCK, cy - 4 * MOCK, cx + 4 * MOCK, cy + 4 * MOCK], fill=dot + (255,))

    # Sidebar.
    side_w = 126 * MOCK
    draw.rectangle([win[0], win[1] + 24 * MOCK, win[0] + side_w, win[3]], fill=SIDEBAR)

    ui, mono, small = font(11 * MOCK), font(10 * MOCK, mono=True), font(8 * MOCK)
    for label, y in headers:
        draw.text((win[0] + 14 * MOCK, y), label.upper(), font=small, fill=MUTED)

    for index, ((label, color, _), y) in enumerate(zip(TREE, rows)):
        if index == selected:
            draw.rounded_rectangle(
                [win[0] + 7 * MOCK, y - 3 * MOCK, win[0] + side_w - 7 * MOCK, y + 15 * MOCK],
                radius=4 * MOCK, fill=SELECTED,
            )
        # cmux marks a Workspace's color as a bar down its leading edge, not a bullet.
        draw.rounded_rectangle(
            [win[0] + 12 * MOCK, y + 1 * MOCK, win[0] + 15 * MOCK, y + 12 * MOCK],
            radius=1 * MOCK, fill=dimmed(color, 1.0),
        )
        draw.text((win[0] + 23 * MOCK, y), label, font=ui,
                  fill=TEXT if index == selected else MUTED)

    # Terminal.
    tx, ty = win[0] + side_w + 16 * MOCK, win[1] + 38 * MOCK
    palette = {"muted": MUTED, "text": TEXT,
               "run": dimmed(BLUE, 1.0), "done": dimmed(GREEN, 1.0)}
    for kind, line in TRANSCRIPTS[selected]:
        draw.text((tx, ty), line, font=mono, fill=palette[kind])
        ty += 20 * MOCK

    if cursor_xy:
        cursor(draw, cursor_xy[0], cursor_xy[1], click)
    return canvas, origins, bar_h


def make_click():
    """Cursor travels to the finished agent's glyph, clicks, and the Workspace switches."""
    # Probe one frame for the glyph origins, so the cursor aims at the real thing.
    _, origins, bar_h = mock_frame(1.0, WATCHING, None, 0)
    target = (origins[FINISHED] + 6 * MOCK, bar_h // 2)
    start = (300 * MOCK, 170 * MOCK)

    steps = [
        ("hold", 6, 0),      # the finished agent sits there at full brightness
        ("move", 12, 0),     # cursor travels up to its glyph
        ("click", 5, 1),     # ring
        ("after", 14, 2),    # Workspace switched, glyph settled
    ]
    frames = []
    i = 0
    total = sum(n for _, n, _ in steps)
    for kind, count, _ in steps:
        for step in range(count):
            phase = 0.5 + 0.5 * math.sin(2 * math.pi * i / (total | 1))
            if kind == "hold":
                pos, click, selected = start, 0, WATCHING
            elif kind == "move":
                # Ease-out so the cursor decelerates onto the glyph.
                t = 1 - (1 - (step + 1) / count) ** 3
                pos = (start[0] + (target[0] - start[0]) * t,
                       start[1] + (target[1] - start[1]) * t)
                click, selected = 0, WATCHING
            elif kind == "click":
                pos, click, selected = target, (step + 1) / count, WATCHING
            else:
                pos, click, selected = target, 0, FINISHED
            frame, _, _ = mock_frame(phase, selected, pos, click)
            frames.append(frame)
            i += 1
    save_apng(frames, f"{OUT}/click.png", round(1000 / FPS))


def main():
    os.makedirs(OUT, exist_ok=True)
    make_pulse()
    make_click()


if __name__ == "__main__":
    main()
