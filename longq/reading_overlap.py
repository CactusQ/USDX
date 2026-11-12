#!/usr/bin/env python3
"""reading_overlap.py FRAME.jpg PLAYERS [FRAME PLAYERS ...]: pixel check of the reading stack in a
reading_frames.sh screenshot (operator 2026-11-12: romaji under both lyric lines must scale for 1-4p).

Finds the text rows in the lyric box from their dark outline pixels (lyric + romaji are drawn with a
black outline, the bar behind them is a light overlay) and checks, in pixels:
  - >= 3 text bands (line, romaji, next line, next-line romaji; a Latin next line has no romaji)
  - no band starts above the note-lane bottom + margin (LongqNotesBottom: 460 / 478 for 3, 6p, +4)
  - no band reaches the time bar (577 theme units)
  - bands never touch: >= 1 empty pixel row between neighbours
Prints one line per frame and exits 1 if any frame fails.
"""
import sys
from PIL import Image
DARK = 130  # outline pixels; romaji outlines are drawn at 70 % alpha over the light bar

def bands(img, y0, y1):
    w, h = img.size
    px = img.load()
    x0, x1 = int(w * 0.05), int(w * 0.95)
    prof = []
    for y in range(max(0, y0), min(h, y1)):
        n = 0
        for x in range(x0, x1, 2):
            r, g, b = px[x, y][:3]
            if max(r, g, b) < DARK:
                n += 1
        prof.append((y, n))
    thr = max(3, int((x1 - x0) / 2 * 0.004))
    out, cur = [], None
    for y, n in prof:
        if n >= thr:
            cur = [y, y] if cur is None else [cur[0], y]
        elif cur is not None:
            out.append(cur); cur = None
    if cur is not None:
        out.append(cur)
    return [b for b in out if b[1] - b[0] >= 3]  # ignore 1-3 px specks

def row_lum(img, y0, y1):
    w, h = img.size
    px = img.load()
    x0, x1 = int(w * 0.05), int(w * 0.95)
    out = {}
    for y in range(max(0, y0), min(h, y1)):
        s = 0
        for x in range(x0, x1, 4):
            r, g, b = px[x, y][:3]
            s += 0.299 * r + 0.587 * g + 0.114 * b
        out[y] = s / len(range(x0, x1, 4))
    return out

def bar_top(img, y0, y1):
    # the lyric bar is a light overlay: its top edge is the strongest step up in row brightness
    lum = row_lum(img, y0 - 8, y1)
    best, by = -1e9, None
    for y in range(y0, y1 - 6):
        if y - 6 not in lum:
            continue
        d = sum(lum[y + i] for i in range(6)) / 6 - sum(lum[y - 1 - i] for i in range(6)) / 6
        if d > best:
            best, by = d, y
    return by, best

def check(path, players):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    k = h / 600.0
    notes_b = (478 if players in (3, 6) else 460) + 4
    time_top = 577
    top, step = bar_top(img, int((notes_b - 40) * k), int((time_top - 40) * k))
    bs = bands(img, top + 1, int(time_top * k))
    fails = []
    if top < notes_b * k - 2:
        fails.append("lyric box top y=%d px inside the note lanes (limit %.0f px)" % (top, notes_b * k))
    if len(bs) < 3:
        fails.append("only %d text bands" % len(bs))
    if bs and bs[0][0] <= top + 1:
        fails.append("text touches the box top")
    if bs and bs[-1][1] >= time_top * k - 1:
        fails.append("text reaches the time bar (%d >= %.0f px)" % (bs[-1][1], time_top * k))
    gaps = [bs[i + 1][0] - bs[i][1] - 1 for i in range(len(bs) - 1)]
    if any(g < 1 for g in gaps):
        fails.append("rows touch (gaps %s)" % gaps)
    desc = " ".join("%d-%d" % (a, b) for a, b in bs)
    print("%s %dp %dx%d box-top %d px (step %.0f, limit %.0f) bands[%s] gaps%s -> %s" % (
        path.split("/")[-1], players, w, h, top, step, notes_b * k, desc, gaps,
        "OK" if not fails else "FAIL: " + "; ".join(fails)))
    return not fails

if __name__ == "__main__":
    a = sys.argv[1:]
    if not a or len(a) % 2:
        print(__doc__); sys.exit(2)
    ok = all([check(a[i], int(a[i + 1])) for i in range(0, len(a), 2)])
    sys.exit(0 if ok else 1)
