#!/usr/bin/env python3
"""Generate the Last Star environment texture set.

Every texture is drawn procedurally at 4x and box-downsampled, which is what
gives the clean anti-aliased edges - drawing directly at final size produces
jagged alpha on every grass blade and every petal rim.

Style targets, consistent across the set:
  * flat, readable silhouettes with a strong dark rim
  * two- or three-band shading rather than smooth gradients
  * warm greens that stay green in shade (the project has fought a cyan cast)
  * a little per-blade hue variation so nothing tiles visibly
"""
import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

SS = 4  # supersample factor
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "environment")


def canvas(w, h):
    return Image.new("RGBA", (w * SS, h * SS), (0, 0, 0, 0))


def finish(img, w, h, path, bg=None):
    small = img.resize((w, h), Image.LANCZOS)
    if bg is not None:
        flat = Image.new("RGBA", small.size, bg)
        flat.alpha_composite(small)
        small = flat
    small.save(path, optimize=True)
    return path


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def shade(col, f):
    """Scale a colour's brightness, returning RGB only."""
    return tuple(max(0, min(255, int(c * f))) for c in col[:3])


# --------------------------------------------------------------------------
# grass blade
# --------------------------------------------------------------------------
def blade(draw, x, base_y, length, width, lean, col, tip_col, rim=(18, 46, 26)):
    """A single tapered blade: quadratic curve, dark rim, lighter tip."""
    pts = []
    steps = 14
    for i in range(steps + 1):
        t = i / steps
        y = base_y - length * t
        dx = lean * (t ** 1.7) * length
        w = width * (1.0 - t * 0.92) * 0.5
        pts.append((x + dx, y, max(w, 0.6)))
    left = [(p[0] - p[2], p[1]) for p in pts]
    right = [(p[0] + p[2], p[1]) for p in reversed(pts)]
    poly = left + right
    # rim first, then the body inset slightly
    draw.polygon([(px, py) for px, py in poly], fill=tuple(rim[:3]) + (255,))
    inner_l = [(p[0] - p[2] * 0.62, p[1]) for p in pts]
    inner_r = [(p[0] + p[2] * 0.62, p[1]) for p in reversed(pts)]
    draw.polygon(inner_l + inner_r, fill=tuple(col[:3]) + (255,))


## The meadow's card is painted in near-white, not green, and that is the whole
## reason it reads as a meadow instead of as a starburst of green spikes.
##
## The shader owns the colour: it lays a root-to-tip gradient over the card and
## multiplies that by a per-tuft value. A sheet that is already saturated green
## gets that green mixed in on top (the old code blended 35% of the sheet's own
## colour back in), so every tuft lands on the same acid green and the field reads
## as one flat surface. A pale sheet carries only the *shading* - which blade is
## in front, where its rim is, how dark it is at the root - and the shader turns
## that into grass. This is the same trick the old tuft used, and it is why the
## old frame is a soft pale carpet while the new one was a lime starburst.
## Two per-tuft value steps rather than a continuous ramp, because the whole set
## is drawn in two or three bands by design.
PALE_GREENS = [
    (206, 206, 202), (222, 222, 214), (192, 196, 188),
    (232, 232, 224), (186, 190, 182),
]

# Ground cover for the bottom of the card. Without it a tuft has a row of bare
# blade roots sitting on the terrain, which at 0.4 m from the camera reads as
# sticks in dirt; with it the card has a base that merges with the ground plane.
THATCH = (150, 138, 112)


def draw_tuft(draw, cx, cy, scale, rng, palette=None):
    """A dense, even fan of blades from one root.

    The old tuft this replaces drew 18-30 blades with a narrow spread and only
    about a third of the card's width in lean, which is what makes the silhouette
    read as a clump. The first version of this function drew 11-17 blades with
    the full width in lean from each one, and at 256 px it looked like a firework:
    every blade left the root at a visible angle and the card became a starburst
    of separate lines rather than a mass of grass.
    """
    palette = palette or PALE_GREENS
    # A few clods of thatch at the base, then the blades rising out of them.
    # Deliberately sparse and low: a solid bar along the bottom edge is a stripe
    # of sand at the foot of every card, and the meadow tiles into a plaid.
    base_r = scale * 0.26
    for _ in range(5):
        ox = rng.uniform(-base_r, base_r)
        r = rng.uniform(base_r * 0.30, base_r * 0.55)
        draw.ellipse([cx + ox - r, cy - r * 0.34,
                      cx + ox + r, cy + r * 0.30],
                     fill=tuple(shade(THATCH, rng.uniform(0.70, 0.94))) + (255,))

    n = rng.randint(18, 30)
    for i in range(n):
        t = i / max(n - 1, 1)
        # Most blades stand near-upright; only the outermost third lean, and even
        # then by less than half the card's width.
        edge = abs(t - 0.5) * 2.0
        lean = (t - 0.5) * 2.0 * rng.uniform(0.16, 0.52) * (0.55 + edge)
        length = scale * rng.uniform(0.62, 1.0) * (1.0 - 0.30 * edge * edge)
        width = scale * rng.uniform(0.030, 0.058)
        col = rng.choice(palette)
        # Back blades are darker and shorter, front blades lighter: cheap depth.
        depth = 0.74 + 0.26 * (1.0 - abs(lean))
        blade(draw, cx + lean * scale * 0.16, cy, length, width, lean,
              shade(col, depth), lerp(col, (255, 255, 246), 0.30))


BORDER_GREENS = [
    (62, 118, 48), (74, 136, 54), (52, 100, 42), (88, 150, 60),
    (46, 92, 40), (96, 158, 62),
]


def gen_grass(path, w=512, h=512):
    """Normal field grass: dense, even, mid-tone. Reads as a carpet."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(11)
    W, H = w * SS, h * SS
    # One tuft, centred, filling the card. This is an instance card, not a mat:
    # the MultiMesh builds the meadow by stamping this tens of thousands of
    # times, so what it has to be is a single clump with clean alpha.
    #
    # It fills the card's full height and about 80% of its width. The first
    # version filled 90% of the height but the blades were drawn from a point, so
    # the *visible* mass was a narrow spike and the rest of the card was empty -
    # which is why the meadow looked sparse at 27k instances.
    draw_tuft(d, W * 0.5, H * 1.01, H * 0.96, rng)
    # Two shorter companions at the root, off-centre, so the stamp does not read
    # as a symmetrical fountain when repeated. Low and wide, not tall: they widen
    # the silhouette at ground level, which is where the eye reads "carpet".
    draw_tuft(d, W * 0.26, H * 1.01, H * 0.56, rng)
    draw_tuft(d, W * 0.76, H * 1.01, H * 0.50, rng)
    return finish(img, w, h, path)


def gen_border_grass(path, w=512, h=512):
    """Field-edge grass: taller, darker, irregular top edge.

    The border has to be distinguishable at a glance from ordinary grass, which
    it does in the three ways an actual field edge differs: it is taller, it is
    a darker and cooler green, and its silhouette is ragged rather than even.
    """
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(29)
    W, H = w * SS, h * SS
    # A soil-littered base so the edge has something to grow out of.
    for _ in range(140):
        x = rng.uniform(0, W)
        y = rng.uniform(H * 0.86, H)
        r = rng.uniform(H * 0.006, H * 0.016)
        d.ellipse([x - r, y - r * 0.6, x + r, y + r * 0.6],
                  fill=(64, 52, 38, rng.randint(120, 210)))
    draw_tuft(d, W * 0.50, H * 1.01, H * 1.02, rng, BORDER_GREENS)
    draw_tuft(d, W * 0.20, H * 1.01, H * 0.72, rng, BORDER_GREENS)
    draw_tuft(d, W * 0.82, H * 1.01, H * 0.66, rng, BORDER_GREENS)
    return finish(img, w, h, path)


# --------------------------------------------------------------------------
# flowers
# --------------------------------------------------------------------------
def petal(draw, cx, cy, rx, ry, ang, fill, rim=(40, 30, 44), rim_w=None):
    """One petal as a rotated ellipse with a dark rim."""
    pts = []
    ca, sa = math.cos(ang), math.sin(ang)
    steps = 22
    for i in range(steps):
        t = 2 * math.pi * i / steps
        x = rx * math.cos(t)
        y = ry * math.sin(t)
        pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    draw.polygon(pts, fill=tuple(rim[:3]) + (255,))
    inner = [(cx + (p[0] - cx) * 0.80, cy + (p[1] - cy) * 0.80) for p in pts]
    draw.polygon(inner, fill=tuple(fill[:3]) + (255,))


FLOWER_SPECS = [
    # (name, petal count, rx, ry, angle spread, petal colour, centre colour, style)
    ("meadow_white",   5, 0.30, 0.17, "star",   (246, 246, 240), (240, 208, 96), "star"),
    ("buttercup",      5, 0.30, 0.24, "star",   (250, 214, 62),  (250, 176, 40), "star"),
    ("pink_wild",      5, 0.26, 0.16, "star",   (244, 148, 186), (250, 232, 190), "star"),
    ("blue_bell",      1, 0.26, 0.34, "bell",   (108, 156, 240), (250, 250, 250), "bell"),
    ("lavender",       6, 0.20, 0.12, "spike",  (158, 128, 230), (186, 160, 244), "spike"),
    ("poppy",          4, 0.34, 0.28, "star",   (232, 62, 58),   (40, 32, 34),    "star"),
    ("daisy_white",    9, 0.30, 0.10, "star",   (252, 252, 250), (250, 206, 60),  "star"),
    ("orange_wild",    5, 0.26, 0.20, "star",   (250, 148, 54),  (238, 108, 34),  "star"),
    ("violet_small",   5, 0.18, 0.14, "star",   (146, 108, 214), (216, 196, 250), "star"),
    ("cherry_ground",  5, 0.22, 0.16, "star",   (246, 176, 200), (255, 236, 240), "star"),
    ("gold_star",      6, 0.30, 0.13, "star",   (246, 198, 64),  (252, 236, 140), "star"),
    ("blue_five",      5, 0.28, 0.18, "star",   (86, 138, 232),  (236, 240, 252), "star"),
    ("white_lily",     6, 0.34, 0.13, "star",   (252, 250, 246), (248, 216, 96),  "star"),
    ("purple_cluster", 7, 0.16, 0.13, "cluster",(140, 96, 200),  (182, 148, 236), "cluster"),
    ("red_bell",       1, 0.24, 0.32, "bell",   (224, 68, 72),   (250, 214, 200), "bell"),
    ("yellow_daisy",   8, 0.28, 0.11, "star",   (250, 220, 74),  (196, 138, 40),  "star"),
    ("pale_pink",      6, 0.24, 0.17, "star",   (250, 208, 216), (252, 236, 232), "star"),
    ("blue_magical",   6, 0.26, 0.15, "star",   (96, 196, 248),  (222, 248, 255), "star"),
    ("white_cluster",  5, 0.12, 0.10, "cluster",(250, 250, 248), (240, 226, 140), "cluster"),
    ("glow_fantasy",   8, 0.24, 0.14, "star",   (206, 156, 252), (255, 246, 196), "star"),
]


def stem(draw, x, y0, y1, w=5, col=(74, 132, 66)):
    draw.line([(x, y0), (x, y1)], fill=tuple(col) + (255,), width=int(w))


def leaf_simple(draw, x, y, length, ang, col=(72, 130, 62)):
    rx, ry = length, length * 0.34
    ca, sa = math.cos(ang), math.sin(ang)
    pts = []
    for i in range(24):
        t = 2 * math.pi * i / 24
        px = rx * math.cos(t)
        py = ry * math.sin(t)
        pts.append((x + px * ca - py * sa, y + px * sa + py * ca))
    draw.polygon(pts, fill=tuple(col[:3]) + (255,))


def draw_flower(draw, cx, cy, scale, spec, rng):
    name, count, prx, pry, style, col, centre, kind = spec
    # stem
    stem(draw, cx, cy, cy + scale * 1.05, w=scale * 0.045)
    leaf_simple(draw, cx + scale * 0.13, cy + scale * 0.62, scale * 0.34, -0.5)
    leaf_simple(draw, cx - scale * 0.12, cy + scale * 0.80, scale * 0.30, math.pi + 0.5)

    if kind == "bell":
        # Hanging bell: an inverted cup, darker inside.
        rx, ry = scale * prx, scale * pry
        draw.ellipse([cx - rx, cy + ry * 0.15, cx + rx, cy + ry * 1.5],
                     fill=tuple(shade(col, 0.86)) + (255,))
        draw.ellipse([cx - rx * 0.72, cy + ry * 0.10, cx + rx * 0.72, cy + ry * 0.95],
                     fill=tuple(col) + (255,))
        draw.ellipse([cx - rx * 0.34, cy + ry * 0.62, cx + rx * 0.34, cy + ry * 1.10],
                     fill=tuple(centre) + (255,))
        return
    if kind == "spike":
        for i in range(count):
            t = i / max(count - 1, 1)
            yy = cy - scale * 0.10 - t * scale * 0.95
            rr = scale * (0.16 - t * 0.08)
            draw.ellipse([cx - rr, yy - rr * 1.5, cx + rr, yy + rr * 1.5],
                         fill=tuple(lerp(col, centre, t * 0.55)) + (255,))
        return
    if kind == "cluster":
        for i in range(count):
            a = (i / count) * 2 * math.pi
            rr = scale * 0.20
            px = cx + math.cos(a) * rr
            py = cy + math.sin(a) * rr * 0.85
            petal(draw, px, py, scale * prx * 0.85, scale * pry * 0.85,
                  a, lerp(col, centre, 0.25))
        draw.ellipse([cx - scale * 0.07, cy - scale * 0.07,
                      cx + scale * 0.07, cy + scale * 0.07],
                     fill=tuple(centre) + (255,))
        return

    # star / radial arrangement
    for i in range(count):
        a = (i / count) * 2 * math.pi - math.pi * 0.5
        petal(draw, cx + math.cos(a) * scale * prx * 0.52,
              cy + math.sin(a) * scale * pry * 0.52,
              scale * prx, scale * pry, a, col)
    rr = scale * 0.14
    draw.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=tuple(centre) + (255,))
    draw.ellipse([cx - rr * 0.55, cy - rr * 0.55, cx + rr * 0.55, cy + rr * 0.55],
                 fill=tuple(shade(centre, 1.14)) + (255,))


def gen_flowers(path, cols=5, rows=4, cell=200):
    """A 5x4 atlas of twenty genuinely different flowers."""
    assert len(FLOWER_SPECS) == 20
    w, h = cols * cell, rows * cell
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(77)
    for idx, spec in enumerate(FLOWER_SPECS):
        gx = idx % cols
        gy = idx // cols
        cx = (gx + 0.5) * cell * SS
        cy = (gy + 0.34) * cell * SS
        draw_flower(d, cx, cy, cell * SS * 0.30, spec, rng)
    return finish(img, w, h, path)


# --------------------------------------------------------------------------
# leaves
# --------------------------------------------------------------------------
LEAF_SPECS = [
    ("green",  (74, 148, 66),  "oval"),
    ("red",    (198, 62, 52),  "maple"),
    ("pink",   (238, 158, 196), "oval"),
    ("brown",  (140, 96, 52),  "maple"),
    ("yellow", (232, 190, 58), "oval"),
]


def leaf_shape(draw, cx, cy, length, kind, col, vein=(255, 255, 255, 70)):
    """Draw one leaf, pointed at both ends, with a midrib and side veins."""
    if kind == "maple":
        # Three-lobed silhouette: five points around a centre.
        pts = []
        lobes = 5
        for i in range(lobes * 2):
            a = -math.pi / 2 + i * math.pi / lobes
            r = length if i % 2 == 0 else length * 0.44
            pts.append((cx + math.cos(a) * r, cy + math.sin(a) * r * 0.92))
        draw.polygon(pts, fill=tuple(shade(col, 0.66)) + (255,))
        inner = [(cx + (p[0] - cx) * 0.84, cy + (p[1] - cy) * 0.84) for p in pts]
        draw.polygon(inner, fill=tuple(col) + (255,))
    else:
        pts = []
        steps = 30
        for i in range(steps + 1):
            t = i / steps
            y = -length + 2 * length * t
            # Width follows a sine lobe, zero at both tips.
            wdt = length * 0.46 * math.sin(math.pi * t)
            pts.append((cx + wdt, cy + y))
        for i in range(steps, -1, -1):
            t = i / steps
            y = -length + 2 * length * t
            wdt = length * 0.46 * math.sin(math.pi * t)
            pts.append((cx - wdt, cy + y))
        draw.polygon(pts, fill=tuple(shade(col, 0.66)) + (255,))
        inner = [(cx + (p[0] - cx) * 0.84, cy + (p[1] - cy) * 0.84) for p in pts]
        draw.polygon(inner, fill=tuple(col) + (255,))
    # midrib
    draw.line([(cx, cy - length * 0.92), (cx, cy + length * 0.92)],
              fill=tuple(shade(col, 0.62)) + (255,), width=max(2, int(length * 0.055)))
    for i in range(1, 5):
        t = i / 5.0
        y = cy - length * 0.82 + length * 1.64 * t
        for s in (-1, 1):
            draw.line([(cx, y), (cx + s * length * 0.30 * math.sin(math.pi * t), y + length * 0.16)],
                      fill=tuple(shade(col, 0.68)) + (255,), width=max(1, int(length * 0.03)))


def gen_leaf(path, cell=220):
    """Five distinct leaves stacked in one atlas, plus fallen variants."""
    w, h = cell * 5, cell
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    for i, (name, col, kind) in enumerate(LEAF_SPECS):
        cx = (i + 0.5) * cell * SS
        cy = cell * SS * 0.50
        leaf_shape(d, cx, cy, cell * SS * 0.36, kind, col)
        if name == "brown":
            # Fallen-leaf variants scattered in the lower band of this cell.
            rng = random.Random(5)
            for _ in range(7):
                lx = cx + rng.uniform(-cell * 0.40, cell * 0.40) * SS
                ly = cell * SS * rng.uniform(0.76, 0.94)
                leaf_shape(d, lx, ly, cell * SS * rng.uniform(0.055, 0.085), kind,
                           shade(col, rng.uniform(0.8, 1.15)))
    return finish(img, w, h, path)


# --------------------------------------------------------------------------
# rocks / pebbles / bush / wood / trunks
# --------------------------------------------------------------------------
def blob_polygon(cx, cy, r, rng, wobble=0.26, n=16):
    pts = []
    for i in range(n):
        a = 2 * math.pi * i / n
        rr = r * (1.0 + rng.uniform(-wobble, wobble))
        pts.append((cx + math.cos(a) * rr, cy + math.sin(a) * rr * 0.82))
    return pts


def draw_rock(draw, cx, cy, r, rng, base, moss=None):
    """A rock: faceted silhouette, lit top face, darker base, optional moss."""
    pts = blob_polygon(cx, cy, r, rng, 0.22, 14)
    draw.polygon(pts, fill=tuple(shade(base, 0.52)) + (255,))
    inner = [(cx + (p[0] - cx) * 0.86, cy + (p[1] - cy) * 0.86) for p in pts]
    draw.polygon(inner, fill=tuple(base) + (255,))
    # Lit facet: an offset polygon toward the upper left.
    hi = [(cx - r * 0.16 + (p[0] - cx) * 0.52, cy - r * 0.20 + (p[1] - cy) * 0.52)
          for p in pts]
    draw.polygon(hi, fill=tuple(shade(base, 1.20)) + (255,))
    # Cracks.
    for _ in range(rng.randint(1, 3)):
        x0 = cx + rng.uniform(-r * 0.5, r * 0.5)
        y0 = cy + rng.uniform(-r * 0.4, r * 0.2)
        draw.line([(x0, y0), (x0 + rng.uniform(-r * 0.3, r * 0.3),
                              y0 + rng.uniform(r * 0.2, r * 0.55))],
                  fill=tuple(shade(base, 0.46)) + (255,), width=max(2, int(r * 0.05)))
    if moss:
        for _ in range(rng.randint(4, 9)):
            mx = cx + rng.uniform(-r * 0.55, r * 0.55)
            my = cy - r * rng.uniform(0.15, 0.62)
            mr = r * rng.uniform(0.10, 0.24)
            draw.ellipse([mx - mr, my - mr * 0.7, mx + mr, my + mr * 0.7],
                         fill=tuple(moss) + (255,))


STONES = [(128, 126, 130), (150, 146, 142), (106, 110, 118), (138, 128, 116),
          (118, 124, 126), (160, 156, 150)]


def gen_rocks(path, w=512, h=512):
    """A rock collection: small through large, angular, smooth, mossy, cracked."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(303)
    W, H = w * SS, h * SS
    specs = [
        (0.16, 0.16, 0.13, False, False), (0.40, 0.14, 0.10, True, False),
        (0.68, 0.15, 0.15, False, True),  (0.87, 0.16, 0.09, True, False),
        (0.18, 0.46, 0.19, True, True),   (0.48, 0.44, 0.23, False, False),
        (0.80, 0.45, 0.17, True, True),
        (0.22, 0.78, 0.15, False, False), (0.52, 0.79, 0.18, True, True),
        (0.82, 0.80, 0.13, False, False),
    ]
    for (fx, fy, fr, angular, mossy) in specs:
        base = rng.choice(STONES)
        draw_rock(d, fx * W, fy * H, fr * min(W, H), rng, base,
                  moss=(76, 122, 58) if mossy else None)
    return finish(img, w, h, path)


def gen_pebbles(path, w=512, h=512):
    """Small stones: a scatter of smooth and rough pebbles in variant colours."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    draw = d
    rng = random.Random(404)
    W, H = w * SS, h * SS
    for _ in range(150):
        cx = rng.uniform(0.04, 0.96) * W
        cy = rng.uniform(0.10, 0.94) * H
        r = rng.uniform(0.016, 0.052) * min(W, H)
        base = rng.choice(STONES + [(112, 100, 86), (146, 132, 112), (96, 92, 90)])
        if rng.random() < 0.55:
            # smooth, rounded river pebble
            draw.ellipse([cx - r, cy - r * 0.78, cx + r, cy + r * 0.78],
                         fill=tuple(shade(base, 0.55)) + (255,))
            draw.ellipse([cx - r * 0.86, cy - r * 0.68, cx + r * 0.86, cy + r * 0.68],
                         fill=tuple(base) + (255,))
            draw.ellipse([cx - r * 0.46, cy - r * 0.46, cx + r * 0.30, cy + r * 0.18],
                         fill=tuple(shade(base, 1.16)) + (255,))
        else:
            draw_rock(d, cx, cy, r, rng, base)
    return finish(img, w, h, path)


def gen_bush(path, w=512, h=512):
    """Dense flowering bush: layered lobes of foliage with blooms on top."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    draw = d
    rng = random.Random(505)
    W, H = w * SS, h * SS
    greens = [(62, 122, 54), (74, 140, 60), (52, 106, 48), (88, 156, 68)]
    # Foliage mass: overlapping lobes, back to front.
    for layer in range(3):
        depth = 0.72 + 0.16 * layer
        for _ in range(26):
            cx = rng.uniform(0.16, 0.84) * W
            cy = rng.uniform(0.42, 0.86) * H
            r = rng.uniform(0.07, 0.15) * min(W, H) * (0.85 + 0.3 * layer)
            col = shade(rng.choice(greens), depth)
            draw.ellipse([cx - r, cy - r * 0.92, cx + r, cy + r * 0.92],
                         fill=tuple(col) + (255,))
            # leaf highlight
            draw.ellipse([cx - r * 0.42, cy - r * 0.60, cx + r * 0.34, cy + r * 0.10],
                         fill=tuple(shade(col, 1.22)) + (255,))
    # Blooms.
    for _ in range(26):
        cx = rng.uniform(0.18, 0.82) * W
        cy = rng.uniform(0.34, 0.74) * H
        r = rng.uniform(0.012, 0.024) * min(W, H)
        col = rng.choice([(250, 236, 244), (246, 196, 220), (252, 224, 130)])
        for i in range(5):
            a = i / 5 * 2 * math.pi
            px = cx + math.cos(a) * r
            py = cy + math.sin(a) * r * 0.9
            draw.ellipse([px - r * 0.7, py - r * 0.7, px + r * 0.7, py + r * 0.7],
                         fill=tuple(col) + (255,))
        draw.ellipse([cx - r * 0.42, cy - r * 0.42, cx + r * 0.42, cy + r * 0.42],
                     fill=(250, 206, 80, 255))
    return finish(img, w, h, path)


def _grain(draw, x0, y0, x1, y1, rng, base, rows, amp, wob=0.0):
    """Long horizontal grain lines with a wobble, the classic wood read."""
    for i in range(rows):
        t = (i + 0.5) / rows
        y = y0 + (y1 - y0) * t
        pts = []
        steps = 40
        ph = rng.uniform(0, math.tau)
        for k in range(steps + 1):
            u = k / steps
            yy = y + math.sin(u * math.tau * 1.4 + ph) * amp * (1.0 if wob == 0 else wob)
            pts.append((x0 + (x1 - x0) * u, yy))
        col = shade(base, rng.uniform(0.80, 1.14))
        draw.line(pts, fill=tuple(col) + (255,), width=max(2, int((y1 - y0) / rows * 0.30)))


def gen_wood(path, w=512, h=512):
    """Normal wood: straight-ish grain, knots, subtle imperfections."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(606)
    W, H = w * SS, h * SS
    base = (150, 104, 62)
    img.paste(Image.new("RGBA", (W, H), tuple(base) + (255,)))
    # broad tone bands
    for i in range(9):
        y = H * i / 9
        d.rectangle([0, y, W, y + H / 9],
                    fill=tuple(shade(base, rng.uniform(0.92, 1.07))) + (255,))
    _grain(d, 0, 0, W, H, rng, base, 34, H * 0.006)
    # knots
    for _ in range(4):
        kx = rng.uniform(0.1, 0.9) * W
        ky = rng.uniform(0.1, 0.9) * H
        for r in range(9, 1, -2):
            d.ellipse([kx - r * 3, ky - r * 2, kx + r * 3, ky + r * 2],
                      fill=tuple(shade(base, 0.70 + r * 0.017)) + (255,))
    return finish(img, w, h, path)


def gen_wood_striped(path, w=512, h=512):
    """Striped wood: strong alternating light/dark bands, decorative."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(707)
    W, H = w * SS, h * SS
    light = (176, 132, 82)
    dark = (118, 78, 44)
    bands = 11
    for i in range(bands):
        y0 = H * i / bands
        y1 = H * (i + 1) / bands
        col = light if i % 2 == 0 else dark
        d.rectangle([0, y0, W, y1], fill=tuple(col) + (255,))
        _grain(d, 0, y0, W, y1, rng, col, 5, (y1 - y0) * 0.10)
    return finish(img, w, h, path)


def gen_trunk(path, w=512, h=512, stripped=False):
    """Bark cylinder unwrap (or bark with stripped pale sections)."""
    img = canvas(w, h)
    d = ImageDraw.Draw(img)
    rng = random.Random(808 if not stripped else 909)
    W, H = w * SS, h * SS
    bark = (98, 76, 58)
    img.paste(Image.new("RGBA", (W, H), tuple(bark) + (255,)))
    # vertical bark plates
    for _ in range(70):
        x = rng.uniform(0, W)
        wdt = rng.uniform(0.012, 0.045) * W
        y0 = rng.uniform(-0.1, 0.9) * H
        hgt = rng.uniform(0.15, 0.5) * H
        col = shade(bark, rng.uniform(0.68, 1.30))
        d.rounded_rectangle([x, y0, x + wdt, y0 + hgt],
                            radius=wdt * 0.5, fill=tuple(col) + (255,))
    # deep cracks
    for _ in range(26):
        x = rng.uniform(0, W)
        pts = [(x, rng.uniform(-0.1, 0.2) * H)]
        for k in range(6):
            x += rng.uniform(-0.02, 0.02) * W
            pts.append((x, pts[-1][1] + H * 0.15))
        d.line(pts, fill=tuple(shade(bark, 0.42)) + (255,), width=max(3, int(W * 0.008)))
    # knots
    for _ in range(3):
        kx = rng.uniform(0.1, 0.9) * W
        ky = rng.uniform(0.1, 0.9) * H
        for r in range(14, 1, -2):
            d.ellipse([kx - r, ky - r * 1.3, kx + r, ky + r * 1.3],
                      fill=tuple(shade(bark, 0.60 + r * 0.012)) + (255,))
    if stripped:
        # Irregular windows where the bark is gone, showing pale wood.
        for _ in range(5):
            sx = rng.uniform(0.05, 0.80) * W
            sy = rng.uniform(0.05, 0.70) * H
            sw = rng.uniform(0.10, 0.24) * W
            sh = rng.uniform(0.18, 0.38) * H
            pts = [(sx + sw * 0.5 + math.cos(a) * sw * rng.uniform(0.42, 0.5),
                    sy + sh * 0.5 + math.sin(a) * sh * rng.uniform(0.42, 0.5))
                   for a in [2 * math.pi * i / 12 for i in range(12)]]
            d.polygon(pts, fill=(214, 178, 128, 255))
            inner = [(sx + sw * 0.5 + (p[0] - (sx + sw * 0.5)) * 0.90,
                      sy + sh * 0.5 + (p[1] - (sy + sh * 0.5)) * 0.90) for p in pts]
            d.polygon(inner, fill=(198, 160, 110, 255))
            _grain(d, sx, sy, sx + sw, sy + sh, rng, (198, 160, 110), 7, sh * 0.05)
            # torn bark edge
            for _ in range(16):
                ex = rng.uniform(sx, sx + sw)
                ey = rng.choice([sy, sy + sh])
                d.line([(ex, ey), (ex + rng.uniform(-8, 8), ey + rng.uniform(-14, 14))],
                       fill=tuple(shade(bark, 0.72)) + (255,), width=max(2, int(W * 0.004)))
    return finish(img, w, h, path)


def generate_all():
    import os
    paths = {
        "grass": (os.path.join(OUT, "grass"), [("grass.png", gen_grass), ("border_grass.png", gen_border_grass)]),
        "rocks": (os.path.join(OUT, "rocks"), [("rocks.png", gen_rocks)]),
        "pebbles": (os.path.join(OUT, "pebbles"), [("pebbels.png", gen_pebbles)]),
        "bushes": (os.path.join(OUT, "bushes"), [("bush.png", gen_bush)]),
        "flowers": (os.path.join(OUT, "flowers"), [("flowers.png", gen_flowers)]),
        "leaves": (os.path.join(OUT, "leaves"), [("leaf.png", gen_leaf)]),
        "wood": (os.path.join(OUT, "wood"), [("wood.png", gen_wood), ("wood_striped.png", gen_wood_striped)]),
        "trees": (os.path.join(OUT, "trees"), [("trunk.png", gen_trunk),
                                               ("trunk_stripped.png", lambda p: gen_trunk(p, stripped=True))]),
    }
    made = []
    for _, (folder, items) in paths.items():
        os.makedirs(folder, exist_ok=True)
        for fname, fn in items:
            made.append(fn(os.path.join(folder, fname)))
    return made


## The meadow's tuft, on its own.
##
## The full environment set this script used to draw has been retired - the valley
## is built from a 3D art pack now - but the grass came back: two crossed
## alpha-cut cards are 4 triangles against the pack tuft's 64, and the meadow is
## the one surface in the game that is drawn tens of thousands of times. So the
## grass source stays, at 256 rather than 512 because a card is 0.6 m wide and the
## extra resolution was never visible.
def generate_grass_atlas(out_dir="assets/grass"):
    os.makedirs(out_dir, exist_ok=True)
    return [gen_grass(os.path.join(out_dir, "tuft.png"), 256, 256)]


if __name__ == "__main__":
    if "--grass-atlas" in sys.argv:
        for p in generate_grass_atlas():
            print(p)
    else:
        for p in generate_all():
            print(p)
