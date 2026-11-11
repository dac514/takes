#!/usr/bin/env python3
"""Draw cover.png (600x350) and thumbnail.png (120x45) for the tool bundle.

The pictures use the same 5x7 pixel font and the same take colours as the
lanes view, so the page on renoise.com looks like the tool. Needs Pillow.

usage: python3 scripts/make_art.py [bundle_dir]
"""
import math
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = Path(sys.argv[1]) if len(sys.argv) > 1 else next(ROOT.glob("*.xrnx"))

BACK = (27, 27, 30)
PANEL = (16, 16, 18)
BEAT = (38, 38, 42)
TEXT = (232, 232, 236)
DIM = (150, 150, 158)
FAINT = (86, 86, 94)
TAKES = [(240, 128, 60), (70, 185, 125), (85, 155, 245), (225, 95, 150), (205, 185, 65)]


def load_glyphs():
    """Read the glyph table of src/pixelfont.lua, so the art uses the tool's own font."""
    text = (BUNDLE / "src" / "pixelfont.lua").read_text()
    glyphs = {}
    for char, rows in re.findall(r'\["(.)"\] = "([.# ]+)"', text):
        glyphs[char] = rows.split()
    return glyphs


GLYPHS = load_glyphs()


def text_width(s, scale):
    return len(s) * 6 * scale - scale


def draw_text(d, s, x, y, scale, color):
    for i, char in enumerate(s.upper()):
        rows = GLYPHS.get(char, GLYPHS["-"])
        for ry, row in enumerate(rows):
            for rx, bit in enumerate(row):
                if bit == "#":
                    px, py = x + (i * 6 + rx) * scale, y + ry * scale
                    d.rectangle([px, py, px + scale - 1, py + scale - 1], fill=color)


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def lane(d, x, y, w, h, rows, notes, color, used, curve, comp_colors=None):
    """One lane: a notes strip and a moves strip, with time running downward."""
    row_h = h / rows
    notes_w = round(w * 0.5)
    for sx, sw in ((x, notes_w), (x + notes_w + 2, w - notes_w - 2)):
        d.rectangle([sx, y, sx + sw - 1, y + h - 1], fill=PANEL)
        for r in range(0, rows, 4):
            d.rectangle([sx, y + r * row_h, sx + sw - 1, y + (r + 1) * row_h - 1], fill=BEAT)
    for r in range(rows):
        owner = comp_colors[r] if comp_colors else (color if used(r) else None)
        if owner:
            top, bottom = y + r * row_h, y + (r + 1) * row_h - 1
            for sx, sw in ((x, notes_w), (x + notes_w + 2, w - notes_w - 2)):
                d.rectangle([sx, top, sx + sw - 1, bottom], fill=mix(PANEL, owner, 0.3))
                d.rectangle([sx, top, sx + 2, bottom], fill=owner)
    for r, length in notes:
        bright = comp_colors is not None or used(r)
        d.rectangle(
            [x + 6, y + r * row_h + 2, x + 6 + round(length * 0.65), y + (r + 1) * row_h - 3],
            fill=TEXT if bright else FAINT,
        )
    mx, mw = x + notes_w + 7, w - notes_w - 11
    points = [(mx + curve(r / rows) * mw, y + r * row_h + row_h / 2) for r in range(rows)]
    d.line(points, fill=color if not comp_colors else DIM, width=2)


def cover():
    img = Image.new("RGB", (600, 350), BACK)
    d = ImageDraw.Draw(img)

    # Left: the name and what the tool does.
    draw_text(d, "TAKES", 36, 64, 8, TEXT)
    for i, c in enumerate(TAKES[:4]):
        d.rectangle([36 + i * 58, 134, 36 + i * 58 + 50, 139], fill=c)
    draw_text(d, "COMPING FOR RENOISE", 36, 162, 2, TEXT)
    for i, line in enumerate(["RECORD PASSES OVER A LOOP", "KEEP EVERY PASS AS A TAKE", "SWIPE TO PICK THE BEST PARTS"]):
        draw_text(d, line, 36, 204 + i * 22, 1, DIM)
        d.rectangle([36 - 10, 204 + i * 22 + 2, 36 - 7, 204 + i * 22 + 5], fill=TAKES[i])
    draw_text(d, "NOTES   EFFECT COLUMNS   AUTOMATION", 36, 292, 1, FAINT)

    # Right: the comp lane and four takes.
    rows, top, h = 24, 44, 276
    x0, lane_w, gap = 296, 47, 7
    curves = [
        lambda t: 0.15 + 0.7 * t,
        lambda t: 0.5 + 0.38 * math.sin(t * 7),
        lambda t: 0.85 - 0.7 * t,
        lambda t: 0.5 + 0.4 * math.sin(t * 13) * math.sin(t * 4),
    ]
    patterns = [
        [(0, 20), (4, 14), (8, 20), (12, 14), (16, 20), (20, 14)],
        [(0, 20), (3, 12), (6, 16), (8, 22), (12, 12), (16, 20), (19, 12), (22, 16)],
        [(1, 16), (5, 20), (9, 12), (13, 20), (17, 16), (21, 12)],
        [(0, 12), (2, 20), (4, 12), (6, 20), (10, 16), (14, 20), (18, 12), (20, 20)],
    ]
    owners = [0] * 8 + [1] * 6 + [3] * 6 + [1] * 4  # which take each comp row uses
    comp_notes = [n for n in sum(([(r, l) for r, l in patterns[t] if owners[r] == t] for t in range(4)), [])]
    draw_text(d, "COMP", x0, top - 14, 1, TEXT)
    lane(d, x0, top, lane_w, h, rows, comp_notes, DIM, None, curves[2], [TAKES[o] for o in owners])
    for t in range(4):
        x = x0 + lane_w + gap + 6 + t * (lane_w + gap)
        draw_text(d, "TAKE %d" % (t + 1), x, top - 14, 1, DIM)
        d.rectangle([x, top - 4, x + lane_w - 1, top - 3], fill=TAKES[t])
        lane(d, x, top, lane_w, h, rows, patterns[t], TAKES[t], lambda r, t=t: owners[r] == t, curves[t])
    # The playhead.
    d.rectangle([x0 - 6, top + 150, x0 + lane_w + 6 + 4 * (lane_w + gap) + 2, top + 151], fill=TEXT)
    img.save(BUNDLE / "cover.png")


def thumbnail():
    img = Image.new("RGB", (120, 45), BACK)
    d = ImageDraw.Draw(img)
    for i, c in enumerate(TAKES[:4]):
        d.rectangle([8 + i * 6, 9, 8 + i * 6 + 3, 35], fill=mix(PANEL, c, 0.35))
        seg = [(9, 20), (15, 30), (11, 24), (21, 35)][i]
        d.rectangle([8 + i * 6, seg[0], 8 + i * 6 + 3, seg[1]], fill=c)
    draw_text(d, "TAKES", 38, 15, 2, TEXT)
    d.rectangle([38, 33, 38 + text_width("TAKES", 2) - 1, 33], fill=FAINT)
    img.save(BUNDLE / "thumbnail.png")


cover()
thumbnail()
print("ok wrote %s and %s" % (BUNDLE / "cover.png", BUNDLE / "thumbnail.png"))
