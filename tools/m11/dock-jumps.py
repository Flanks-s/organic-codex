#!/usr/bin/env python3
"""dock-jumps (InputRun): for each variant, the visible Dock glass whose written frame jumps in one 1/120 s sample around
the Peek opening or Split beginning while the Auto layout still moves. A jump is a step in x, y, width or height larger
than 5 pt and 3x the largest step of the same glass in the 50 ms before it. Glass whose effective alpha (all views up
the chain, on-screen opacity) is below 0.02 on either side, or hidden, is not visible and is skipped (Advisor 11-04).
python3 dock-jumps.py receipt.json"""
import json, sys

for e in json.load(open(sys.argv[1])).get("composeLog", []):
    step = str(e.get("step", ""))
    if not step.startswith("dock-jumps.") or "samples" not in e: continue
    rows, act, opened = e["samples"], e.get("actAt", 0), e.get("peekOpened", -1)
    ids = sorted({k for r in rows for k in r if k != "t"})
    jumps = []
    for gid in ids:
        seq = [(r["t"], r[gid]) for r in rows if gid in r]
        for k in range(1, len(seq)):
            (t0, a), (t1, b) = seq[k - 1], seq[k]
            if a[5] or b[5] or min(a[4], b[4]) < 0.02: continue
            d = max(abs(b[j] - a[j]) for j in range(4))
            before = [max(abs(seq[m][1][j] - seq[m - 1][1][j]) for j in range(4)) for m in range(1, k) if t1 - 0.05 <= seq[m][0] < t1]
            ref = max(before) if before else 0
            if d > 5 and d > 3 * ref: jumps.append((t1, gid, d, ref, a[:4], b[:4], b[4]))
    print(f"{step}: switch {e.get('switchAt', 0):.3f}s, act {act:.3f}s, Peek opened {opened:.3f}s; {len(rows)} samples; "
          f"{len(jumps)} visible one-sample jumps")
    for t1, gid, d, ref, a, b, alpha in jumps[:8]:
        print(f"   {t1:.3f}s {gid}: step {d:.1f} pt (before {ref:.1f}), alpha {alpha:.2f}, "
              f"{[round(v, 1) for v in a]} -> {[round(v, 1) for v in b]}")
