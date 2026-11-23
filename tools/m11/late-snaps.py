#!/usr/bin/env python3
"""Isolated jumps in a recording's movdiff output: a frame that changes a lot of the window right after a quiet stretch,
which is what text snapping into place looks like (M11.3). Motion bursts ramp up; a snap goes from nothing to a lot at once.
Usage: late-snaps.py DIFF.txt [WINDOW_PIXELS]   Prints each snap's time and share of the window, then the count."""
import sys

area = int(sys.argv[2]) if len(sys.argv) > 2 else 1280 * 820
rows = []
for line in open(sys.argv[1]):
    p = line.split()
    try:
        rows.append((float(p[1]), int(p[2]) / area))
    except (IndexError, ValueError):
        pass
snaps = []
for i, (t, share) in enumerate(rows):
    if share < 0.012:
        continue
    before = [s for tt, s in rows[max(0, i - 12):i] if t - 0.1 <= tt < t]
    if all(s < 0.004 for s in before):
        # A motion's first frame is followed by more motion; a snap is followed by rest again.
        after = [s for tt, s in rows[i + 1:i + 13] if t < tt <= t + 0.1]
        if all(s < 0.012 for s in after):
            snaps.append((t, share))
for t, share in snaps:
    print(f"{t:7.3f} s  {share * 100:5.1f} %")
print(f"{len(snaps)} isolated jumps")
