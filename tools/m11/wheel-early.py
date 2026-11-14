#!/usr/bin/env python3
"""M11.8: reads the receipt of a `--demo-input long-early` run (App/InputRun.swift earlyWheelTrials).

Usage: wheel-early.py RECEIPT.json
For each kind of width change and each moment a wheel step was posted after the commit: how long until the reader SAW the transcript move
(the offset moved and the real transcript was showing), whether the step was kept, and the moment each hand-off condition opened.
Also the main-thread turns over 20 ms in the 0.6 s after each commit. Injected events, not a real mouse.
"""
import json
import statistics as st
import sys

r = json.load(open(sys.argv[1]))
log = r.get("composeLog", [])
trials = [e for e in log if str(e.get("step", "")).startswith("wheel ") and "closed" in e]
stalls = [e for e in log if e.get("step") == "stall"]
if not trials:
    sys.exit("no early wheel trials in this receipt")


def span(values):
    return f"{min(values):.2f}-{max(values):.2f}" if values else "-"


print(f"{'kind':12} {'at':>5} {'n':>2} {'seen after commit':>18} {'latency':>11} {'lost':>4} {'shown':>11} {'settle':>11}")
groups = {}
for e in trials:
    groups.setdefault((e["kind"], e["delay"]), []).append(e)
for (kind, delay), es in sorted(groups.items()):
    seen, late, lost = [], [], 0
    for e in es:
        after = [m for m in e["moves"] if m[0] >= e["posted"]]
        if not after or e["fromEnd"] <= 1:
            lost += 1
            continue
        t = max(after[0][0], e["shown"])
        seen.append(t)
        late.append(t - e["posted"])
    print(f"{kind:12} {delay:5.2f} {len(es):2} {span(seen):>18} {span(late):>11} {lost:4} {span([e['shown'] for e in es]):>11} {span([e['settled'] for e in es]):>11}")

print("\nWhen each condition opened, seconds after the commit (last moment it was closed):")
names = ["place24", "speed24", "place16", "speed16", "place8", "speed8", "flight8", "flight4", "flight1.5", "reflow"]
print(f"{'kind':12} " + " ".join(f"{n:>10}" for n in names) + f" {'edge<8':>10} {'shown':>10}")
for kind in sorted({e["kind"] for e in trials}):
    es = [e for e in trials if e["kind"] == kind]
    cols = []
    for n in names:
        vals = [e["closed"].get(n, 0) for e in es]
        cols.append(f"{span(vals):>10}")
    edge = [dict((a, b) for a, b in e["reached"]).get(8.0, 0) for e in es]
    print(f"{kind:12} " + " ".join(cols) + f" {span(edge):>10} {span([e['shown'] for e in es]):>10}")

print("\nMain-thread turns over 20 ms within 0.6 s after a commit:")
for kind in sorted({e["kind"] for e in trials}):
    es = [e for e in trials if e["kind"] == kind]
    hits = []
    for e in es:
        hits += [s["ms"] for s in stalls if e["commitAt"] <= s["began"] <= e["commitAt"] + 0.6]
    print(f"{kind:12} trials {len(es):3}  turns {len(hits):3}  worst {max(hits) if hits else 0:5.1f} ms  median {st.median(hits) if hits else 0:5.1f} ms")
