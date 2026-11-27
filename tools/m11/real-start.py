#!/usr/bin/env python3
"""Real mode-switch start from a live-ab recording: input -> first changed frame, per switch.

The recording only knows relative frame times and WinRec can't be rebuilt without losing its Screen Recording grant, so
the clock bridge is the demo's own "select another" step: its first changed frame is the visible result of a commit made
at the composeLog time of that step (logged right after the step ran). That is good to about two frames.
Usage: real-start.py RUN_DIR... (each holding diff.txt, app/receipt.json, app/timeline.json from mode-latency.py)
"""
import json
import subprocess
import sys
from pathlib import Path

AREA = 1280 * 820
BIG = 0.02  # a frame "really moved" when more than this share of the window changed
COMMIT_TO_FRAME = 0.015


def frames(run):
    rows = []
    for line in (run / "diff.txt").read_text().splitlines():
        parts = line.split()
        try:
            rows.append((float(parts[1]), int(parts[2]) / AREA))
        except (IndexError, ValueError):
            pass
    return rows


def segments(rows):
    """Starts of bursts of big frames, a quiet 250 ms apart."""
    starts, last = [], -1.0
    for t, part in rows:
        if part > BIG:
            if t - last > 0.25:
                starts.append(t)
            last = t
    return starts


def analyse(run):
    receipt = json.loads((run / "app/receipt.json").read_text())
    timeline = run / "app/timeline.json"
    subprocess.run([sys.executable, str(Path(__file__).with_name("mode-latency.py")), "--receipt", str(run / "app/receipt.json"),
                    "--json", str(timeline)], capture_output=True, check=False)
    switches = json.loads(timeline.read_text())["switches"]
    steps = {c["step"]: c["t"] for c in receipt["composeLog"] if "step" in c and "t" in c}
    rows = frames(run)
    starts = segments(rows)
    if len(starts) < 2:
        return [f"{run}: no select-another burst"]
    # The first burst after the first switch's expected time: with a very late first motion, the first burst may be
    # only just before the select step, so pick the burst that best predicts the switch back as well.
    t_select = steps["select another"]
    t_back = steps["to organic"]
    # While streaming, deltas add small bursts; the select step is the one that changes about a quarter of the window at once.
    share = dict(rows)
    quarter = [s for s in starts if 0.18 < share[s] < 0.30] or starts
    if len(quarter) == 1:
        select = quarter[0]
    else:
        select = min(quarter, key=lambda s: min(abs(s + (t_back - t_select) - o) for o in starts if o > s) if any(o > s for o in starts) else 9)
    bridge = select - (t_select + COMMIT_TO_FRAME)
    out = []
    for switch in switches:
        origin = next(p["start"] for p in switch["timeline"] if p["phase"] == "Input")
        v = origin + bridge
        after = [(t, s) for t, s in rows if t >= v]
        first_any = next((t for t, s in after if s > 0.0003), None)
        first_big = next((t for t, s in after if s > BIG), None)
        window = [(t, s) for t, s in after if first_big is not None and first_big <= t < first_big + 0.45]
        gaps = [b[0] - a[0] for a, b in zip(window, window[1:])]
        name = "O>N" if "to=normie" in switch["switch"] else "N>O"
        hit = "hit" if any(p["phase"] == "ModePreparationHit" for p in switch["timeline"]) else \
            "miss" if any(p["phase"] == "ModePreparationMiss" for p in switch["timeline"]) else "-"
        out.append(f"{name} {hit:4} any {round((first_any - v) * 1000) if first_any else -1:4} ms  "
                   f"big {round((first_big - v) * 1000) if first_big else -1:4} ms  "
                   f"first {round(window[0][1] * 100) if window else 0:3}%  max {round(max((s for _, s in window), default=0) * 100):3}%  "
                   f"frames {len(window):3}  gap {round(max(gaps) * 1000) if gaps else 0:3} ms  "
                   f"block {round(switch.get('maxMeasuredMainThreadBlockMs') or 0):3} ms {switch.get('maxMeasuredMainThreadBlockPhase') or ''}")
    return out


for arg in sys.argv[1:]:
    run = Path(arg)
    for line in analyse(run):
        print(f"{run.parent.name}/{run.name} {line}")
