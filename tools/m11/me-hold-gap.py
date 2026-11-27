#!/usr/bin/env python3
# M11.43: the LL grab exception from a Dock frame log (DOCK_FRAME_LOG), per held stretch of LL ("me"): the gap between LL
# and the first bar on its right as written (native), the same gap with both edges rounded outward to the pixel grid at
# SCALE (1 or 2), how far the bar moved from where it was before the grab and on which frame, and whether the pair
# joined. The Advisor's conditions (5d12b8f): the bar moves no more than LL grows, on the grab frame only; the gap stays
# at 12 pt or more on the pixel grid; no join.
# me-hold-gap.py LOG.jsonl [SCALE]
import json, math, sys

scale = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
frames = [json.loads(l) for l in open(sys.argv[1])]
def glass(d, gid):
    return next((g for g in d["glass"] if g["id"] == gid and not g.get("effectiveHidden")), None)
def first_bar(d, me):
    bars = [g for g in d["glass"] if g["id"].startswith("item.") and not g.get("effectiveHidden") and g["frame"][2] > 48
            and g["frame"][0] >= me["frame"][0]]
    return min(bars, key=lambda g: g["frame"][0], default=None)
stretches, cur = [], None
for i, d in enumerate(frames):
    if d.get("meHeld"):
        if cur is None: cur = {"start": i, "frames": []}
        cur["frames"].append(i)
    elif cur is not None:
        cur["end"] = i; stretches.append(cur); cur = None
if cur is not None: cur["end"] = len(frames); stretches.append(cur)
for s in stretches:
    before = frames[s["start"] - 1] if s["start"] > 0 else None
    me0 = glass(before, "me") if before else None
    bar0 = first_bar(before, me0) if me0 else None
    if not (me0 and bar0):
        print(f"held stretch at frame {s['start']}: no LL or bar before it"); continue
    bid, x0, w0 = bar0["id"], bar0["frame"][0], me0["frame"][2]
    print(f"held stretch frames {s['start']}–{s['end']} ({len(s['frames'])}), bar {bid} at x {x0:.3f} before, LL width {w0:.3f}")
    rows, prev = [], x0
    for k, i in enumerate(s["frames"] + [s["end"]] if s["end"] < len(frames) else s["frames"]):
        d = frames[i]; me = glass(d, "me"); bar = glass(d, bid)
        if not (me and bar): continue
        right = me["frame"][0] + me["frame"][2]; left = bar["frame"][0]
        gap = left - right
        grid = (math.floor(left * scale) - math.ceil(right * scale)) / scale
        rows.append((i, k, me["frame"][2], gap, grid, left - x0, left - prev, d.get("meHeld", False)))
        prev = left
    grow = max((r[2] for r in rows if r[7]), default=w0) - w0
    moved = [r for r in rows if abs(r[6]) > 0.001]
    print(f"  LL grows {grow:.3f} pt (half toward the bar {grow / 2:.3f}); bar moves on {len(moved)} frames; "
          f"largest yield {max((r[5] for r in rows), default=0):.3f} pt; smallest gap {min(r[3] for r in rows):.3f} pt, "
          f"on the {scale:g}× pixel grid {min(r[4] for r in rows):.3f} pt; joined frames {sum(r[3] < 0 for r in rows)}")
    for r in moved[:12]:
        print(f"    frame {r[0]} (+{r[1]}{' held' if r[7] else ' after'}): LL width {r[2]:.3f}, gap {r[3]:.3f}, grid {r[4]:.3f}, "
              f"bar yield {r[5]:.3f} (step {r[6]:+.3f})")
