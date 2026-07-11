#!/usr/bin/env python3
"""Pick a label colour for the wallpaper rotator.

Reads a raw-RGB dump of the screen-sized wallpaper on stdin (from ImageMagick)
plus the on-screen label rectangle, and prints one "#rrggbb".

The colour is always a real tone from the image, chosen so that thin, shadowless
label text reads against the spot behind it:

  * Colour image: a saturated accent covering only a minority of the frame (a
    genuine pop) that reads on the spot; otherwise the lightest tone on a
    dark/mid spot, or the darkest on a light spot.
  * Monochrome art: the lightest tone on a dark spot, or the darkest on a light
    spot, whichever reads.

Standard library only. On any error it prints nothing and exits non-zero so the
caller can fall back.
"""

import sys
import argparse
from math import sqrt, atan2, degrees


# ---- colour maths (sRGB D65) ----------------------------------------------

def _lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def rel_y(r, g, b):
    """WCAG relative luminance, 0..1."""
    return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b)


def _fx(t):
    return t ** (1.0 / 3.0) if t > 0.008856 else 7.787 * t + 16.0 / 116.0


def lab(r, g, b):
    """CIE L*a*b*."""
    lr, lg, lb = _lin(r), _lin(g), _lin(b)
    x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
    y = (0.2126 * lr + 0.7152 * lg + 0.0722 * lb)
    z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
    fx, fy, fz = _fx(x), _fx(y), _fx(z)
    return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))


# ---- clustering ------------------------------------------------------------

class Cluster:
    # sx/sy/sx2/sy2 accumulate normalised pixel positions (0..1) so a cluster's
    # spatial spread can be measured: a tight blob vs. scattered noise.
    __slots__ = ("r", "g", "b", "n", "L", "a", "bb", "y", "c",
                 "sx", "sy", "sx2", "sy2")

    def __init__(self, r, g, b, n, sx=0.0, sy=0.0, sx2=0.0, sy2=0.0):
        self.r, self.g, self.b, self.n = r, g, b, n
        self.L, self.a, self.bb = lab(r, g, b)
        self.y = rel_y(r, g, b)
        self.c = sqrt(self.a * self.a + self.bb * self.bb)  # Lab chroma
        self.sx, self.sy, self.sx2, self.sy2 = sx, sy, sx2, sy2


def cluster(hist):
    """hist buckets -> [Cluster] sorted by count, descending."""
    out = []
    for e in hist.values():
        n = e[3]
        if n <= 0:
            continue
        out.append(Cluster(e[0] / n, e[1] / n, e[2] / n, n,
                           e[4], e[5], e[6], e[7]))
    out.sort(key=lambda c: c.n, reverse=True)
    return out


def add(hist, r, g, b, nx=0.0, ny=0.0):
    # 5 bits/channel: fine enough to separate real tones, coarse enough to pool noise.
    key = (r >> 3, g >> 3, b >> 3)
    e = hist.get(key)
    if e is None:
        hist[key] = [r, g, b, 1, nx, ny, nx * nx, ny * ny]
    else:
        e[0] += r
        e[1] += g
        e[2] += b
        e[3] += 1
        e[4] += nx
        e[5] += ny
        e[6] += nx * nx
        e[7] += ny * ny


def spatial_spread(members):
    """Normalised positional std-dev of a set of clusters: ~0 is a tight blob,
    ~0.4 is scattered across the whole frame."""
    n = sum(c.n for c in members)
    if n <= 0:
        return 0.4
    sx = sum(c.sx for c in members) / n
    sy = sum(c.sy for c in members) / n
    vx = max(0.0, sum(c.sx2 for c in members) / n - sx * sx)
    vy = max(0.0, sum(c.sy2 for c in members) / n - sy * sy)
    return sqrt(vx + vy)


# ---- readability against the label spot -----------------------------------

def patch_tiles(patch, ptot):
    """Tones that sit behind the label: every tile covering >=12% of the patch,
    plus its darkest and lightest sizable tile so bright/dark extremes count."""
    if not patch or ptot <= 0:
        return []
    major = [c for c in patch if c.n >= 0.12 * ptot]
    sizable = [c for c in patch if c.n >= 0.07 * ptot]
    if sizable:
        lo = min(sizable, key=lambda c: c.y)
        hi = max(sizable, key=lambda c: c.y)
        for e in (lo, hi):
            if e not in major:
                major.append(e)
    return major or sizable or patch[:1]


def lab_dist(cl, p):
    return sqrt((cl.L - p.L) ** 2 + (cl.a - p.a) ** 2 + (cl.bb - p.bb) ** 2)


def worst_sep(cl, tiles):
    """Worst-case CIELAB deltaE of cl from the tones behind the label."""
    if not tiles:
        return 100.0
    return min(lab_dist(cl, p) for p in tiles)


def wcag_ratio(y1, y2):
    """WCAG contrast ratio (1..21) between two relative luminances."""
    hi, lo = (y1, y2) if y1 >= y2 else (y2, y1)
    return (hi + 0.05) / (lo + 0.05)


def spot_lum(tiles):
    """Count-weighted mean relative luminance of the tones behind the label."""
    if not tiles:
        return 0.5
    return sum(t.y * t.n for t in tiles) / sum(t.n for t in tiles)


# Thin, shadowless text reads only with real luminance contrast, so readability
# is a WCAG ratio rather than a CIELAB deltaE (equal-lightness hues have a large
# deltaE yet blur together for thin glyphs).
CR_MIN = 2.4       # minimum worst-case WCAG ratio for a tone to count as readable


def reads_on(cl, tiles, cr_min=CR_MIN):
    """True if cl reads against every tone behind the label."""
    if not tiles:
        return True
    if worst_sep(cl, tiles) < 10.0:        # essentially the same colour
        return False
    return min(wcag_ratio(cl.y, t.y) for t in tiles) >= cr_min


def extreme_by_spot(palette, tiles, total):
    """The lightest tone on a dark/mid spot, or the darkest on a light spot: the
    real tone that contrasts the spot in the direction the eye expects (never
    darker than an already-dark spot). The small size floor lets faint highlights
    count."""
    cand = [c for c in palette if c.n >= 0.0004 * total] or palette
    if spot_lum(tiles) < 0.5:
        return max(cand, key=lambda c: c.y)
    return min(cand, key=lambda c: c.y)


# ---- selection -------------------------------------------------------------

MONO_C = 8.0       # max chroma below which the image is treated as monochrome


def hue_of(c):
    return degrees(atan2(c.bb, c.a)) % 360.0


def pick_hue_accent(palette, mean_lab, total):
    """Return a saturated representative of the image's characteristic accent hue,
    or None if there is too little colour.

    Colourful pixels are binned by hue and weighted by presence, chroma and
    salience (distance from the image mean), so a small vivid region can outweigh
    a large desaturated one. The winning hue is rebuilt from its saturated core,
    weighted toward its brighter, more populous tones."""
    mL, mA, mB = mean_lab
    colorful = [c for c in palette if c.c >= 12.0]
    if not colorful or sum(c.n for c in colorful) < 0.02 * total:
        return None
    NB = 36
    step = 360.0 / NB
    binw = [0.0] * NB
    binn = [0.0] * NB
    for c in colorful:
        sal = sqrt((c.L - mL) ** 2 + (c.a - mA) ** 2 + (c.bb - mB) ** 2)
        # Salience-weighted, pixel count barely counted, so a small vivid region
        # can outweigh a large bland one.
        binw[int(hue_of(c) / step) % NB] += (c.n ** 0.35) * c.c * (sal + 8.0) ** 1.7
        binn[int(hue_of(c) / step) % NB] += c.n
    merged = lambda i: binw[i] + 0.6 * binw[(i - 1) % NB] + 0.6 * binw[(i + 1) % NB]
    bi = max(range(NB), key=merged)
    center = bi * step + step / 2.0
    members = [c for c in colorful
               if abs((hue_of(c) - center + 180.0) % 360.0 - 180.0) <= 25.0]
    if not members:
        return None
    frac = (binn[bi] + binn[(bi - 1) % NB] + binn[(bi + 1) % NB]) / total
    if frac < 0.003:
        # A tiny accent qualifies only if it is vivid and spatially coherent (one
        # blob, not scattered noise).
        peak_c = max(c.c for c in members)
        if not (frac >= 0.0004 and peak_c >= 40.0 and spatial_spread(members) <= 0.26):
            return None
    # Rebuild from the saturated core, weighted toward the PUREST (highest-chroma),
    # brighter, more populous tones, so the result is a clean vivid colour rather
    # than a washed-out average that muddies a small pop with its dull surroundings.
    # This is the accent's representative for the pop/readability decision; the final
    # emitted colour is snapped to a real image tone in main().
    cmax = max(c.c for c in members)
    core = [c for c in members if c.c >= 0.55 * cmax] or members
    ws = rw = gw = bw = 0.0
    for c in core:
        w = c.n * (0.35 + c.y) * (c.c * c.c)
        rw += w * c.r; gw += w * c.g; bw += w * c.b; ws += w
    if ws <= 0:
        return None
    return Cluster(rw / ws, gw / ws, bw / ws, sum(c.n for c in members))


def nearest_real(target, palette):
    """The actual pooled image tone closest to target, so an emitted colour is
    always a real pixel from the image rather than a computed blend."""
    return min(palette, key=lambda c: (c.L - target.L) ** 2
               + (c.a - target.a) ** 2 + (c.bb - target.bb) ** 2)


# ---- driver ----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sw", type=int, required=True)   # screen / canvas width
    ap.add_argument("--sh", type=int, required=True)   # screen / canvas height
    ap.add_argument("--w", type=int, required=True)    # width of the RGB dump
    ap.add_argument("--patch", required=True)          # "MR MB SAMPW SAMPH" (screen px)
    args = ap.parse_args()

    data = sys.stdin.buffer.read()
    W = args.w
    if W <= 0 or len(data) < 3 * W:
        return 1
    H = len(data) // (3 * W)
    if H <= 0:
        return 1

    mr, mb, sampw, samph = (int(x) for x in args.patch.split())
    sx, sy = W / args.sw, H / args.sh
    # Label rectangle (SouthEast gravity) -> sample-grid pixel bounds.
    px1 = int(round((args.sw - mr - sampw) * sx)); px2 = int(round((args.sw - mr) * sx))
    py1 = int(round((args.sh - mb - samph) * sy)); py2 = int(round((args.sh - mb) * sy))
    px1 = max(0, min(W, px1)); px2 = max(0, min(W, px2))
    py1 = max(0, min(H, py1)); py2 = max(0, min(H, py2))

    whole, patch_h = {}, {}
    sr = sg = sb = 0
    for y in range(H):
        row = y * W * 3
        ny = y / H
        for x in range(W):
            o = row + x * 3
            r, g, b = data[o], data[o + 1], data[o + 2]
            add(whole, r, g, b, x / W, ny)   # positions feed spatial_spread
            sr += r; sg += g; sb += b
            if py1 <= y < py2 and px1 <= x < px2:
                add(patch_h, r, g, b)

    total = W * H
    palette = cluster(whole)
    patch = cluster(patch_h)
    if not palette:
        return 1

    mean = lab(sr / total, sg / total, sb / total)
    ptot = sum(c.n for c in patch) if patch else 0
    tiles = patch_tiles(patch, ptot)

    # Any genuinely colourful region makes this a colour image; only near-neutral
    # art falls through to the monochrome path.
    sig = [c for c in palette if c.n >= 0.0025 * total]
    max_chroma = max((c.c for c in sig), default=0.0)
    # A saturated subject broken into many small clusters (scattered berries, petals)
    # has a low single-cluster chroma yet real colour, so also weigh total saturated
    # coverage before treating the image as monochrome.
    colorful_cov = sum(c.n for c in palette if c.c >= 30.0) / total
    monochrome = max_chroma < MONO_C and colorful_cov < 0.02

    # The label is always a real image tone, chosen by two rules:
    #   * a saturated accent covering only a minority of the frame that reads on
    #     the spot (a genuine pop); otherwise
    #   * the lightest tone on a dark/mid spot, the darkest on a light spot.
    # A saturated colour that fills most of the frame is the background field, not
    # a pop, so it defers to the extreme tone.
    chosen = None
    if monochrome:
        # Close-shade greyscale has no tone that contrasts strongly, so readability
        # wins: the lightest tone on a dark spot, the darkest on a light spot.
        chosen = extreme_by_spot(palette, tiles, total)
    else:
        vivid = pick_hue_accent(palette, mean, total)
        pop = False
        if vivid is not None and vivid.c >= 40.0:   # a real pop is genuinely saturated
            ah = hue_of(vivid)
            # Count coverage only from strong, non-near-black tones of the hue, so a
            # faint background tint is not mistaken for a full-frame field.
            colorful = [c for c in sig if c.c >= 12.0]
            strong = [c for c in colorful if c.c >= 18.0 and c.y >= 0.06]
            vfrac = sum(c.n for c in strong
                        if abs((hue_of(c) - ah + 180.0) % 360.0 - 180.0) <= 25.0) / total
            pop = vfrac < 0.55          # minority coverage = a pop, not the field
        # A saturated pop carries its own separation through chroma, so it needs
        # less luminance contrast to stay legible than a neutral tone would.
        pop_cr = max(1.8, CR_MIN - (vivid.c - 40.0) * 0.015) if pop else CR_MIN
        if pop and reads_on(vivid, tiles, pop_cr):
            chosen = nearest_real(vivid, palette)   # emit a real tone, not the blend
        else:
            chosen = extreme_by_spot(palette, tiles, total)

    if chosen is None:
        chosen = extreme_by_spot(palette, tiles, total)
    r, g, b = chosen.r, chosen.g, chosen.b

    print("#%02x%02x%02x" % (int(r + 0.5), int(g + 0.5), int(b + 0.5)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        sys.exit(1)
