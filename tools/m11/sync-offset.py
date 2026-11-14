#!/usr/bin/env python3
# M11.31 side-by-side: maps a WinRec recording onto the receipt's CACurrentMediaTime clock with the driver's INPUT_SYNC
# squares. Each square's first recorded frame is compared with the display-link targetTimestamp it was put in for.
# Prints each square's offset, their spread and the mapping "rec = log - OFFSET" (WinRec's ptsSeconds start at 0).
# sync-offset.py RUN_DIR [--json]    RUN_DIR holds rec.mov and app/receipt.json.
import json, os, subprocess, sys

run = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
log = json.load(open(os.path.join(run, "app", "receipt.json"))).get("composeLog", [])
syncs = [e for e in log if e.get("step") == "sync"]
if len(syncs) != 3:
    sys.exit(f"{run}: {len(syncs)} sync entries in the receipt (want 3; was the run made with INPUT_SYNC=1?)")
x, y, w, h = syncs[0]["square"]
top = y if syncs[0].get("flipped") else 820 - y - h
# The square's inner part only, so antialiased edges and a neighbouring button don't count.
box = [str(v) for v in (top + 3, top + h - 3, x + 3, x + w - 3)]
env = dict(os.environ, BAND_TO="30")
out = subprocess.run(["swift", os.path.join(here, "band-changes.swift"), os.path.join(run, "rec.mov"), *box],
                     capture_output=True, text=True, env=env).stdout.splitlines()
changes = []
for line in out:
    parts = line.split()
    if len(parts) >= 5 and parts[1] == "max":
        changes.append((float(parts[0]), int(parts[2]), int(parts[4])))
big = [c for c in changes if c[1] >= 100]
# Each square is one change on and one off. A recording that started late misses the first squares, so the squares
# seen are matched to the last syncs, and their spacing has to agree with the logged spacing.
on = big[0::2][:3]
if not on:
    sys.exit(f"{run}: no square in the sync box {box}: {changes[:12]}")
syncs = syncs[3 - len(on):]
for k in range(1, len(on)):
    gap = (on[k][0] - on[k - 1][0]) - (syncs[k]["targetTimestamp"] - syncs[k - 1]["targetTimestamp"])
    if abs(gap) > 0.03:
        sys.exit(f"{run}: square spacing differs from the log by {gap * 1000:.0f} ms: {on}")
offsets = [s["targetTimestamp"] - c[0] for s, c in zip(syncs, on)]
mean = sum(offsets) / len(offsets)
spread = max(offsets) - min(offsets)
result = {"run": run, "offset": mean, "spreadMS": spread * 1000, "squares": [
    {"video": c[0], "target": s["targetTimestamp"], "offset": o} for s, c, o in zip(syncs, on, offsets)]}
if "--json" in sys.argv:
    print(json.dumps(result))
else:
    for q in result["squares"]:
        print(f"  square at video {q['video']:.4f}  target {q['target']:.4f}  offset {q['offset']:.4f}")
    print(f"rec = log - {mean:.4f}   (spread {spread * 1000:.1f} ms)")
