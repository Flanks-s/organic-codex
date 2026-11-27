#!/usr/bin/env python3
"""Press-to-commit of the column switches a `--demo-input switch-seq` run made (App/InputRun.swift).
Usage: input-switches.py RECEIPT.json   Prints one row per press: how long the pointer rested, ms to commit, prepared or not."""
import json
import sys

r = json.load(open(sys.argv[1]))
presses = [e for e in r["composeLog"] if e.get("step") == "switch press"]
switches = [s for s in r["switches"] if "at" in s]
rows = []
for k, p in enumerate(presses):
    end = presses[k + 1]["t"] if k + 1 < len(presses) else p["t"] + 2
    s = next((x for x in switches if p["t"] <= x["at"] < end), None)
    if not s:
        rows.append((p["wait"], None, None, None))
    else:
        rows.append((p["wait"], (s["at"] - p["t"]) * 1000, s.get("prewarmed"), s.get("reason")))
for wait, ms, hit, reason in rows:
    print(f"rest {wait:5.2f} s  commit {'-' if ms is None else f'{ms:6.1f} ms'}  {'hit ' if hit else 'miss'}  {reason}")
hits = [m for _, m, h, _ in rows if m is not None and h]
miss = [m for _, m, h, _ in rows if m is not None and not h]
if hits:
    print(f"hit  {len(hits)}: {min(hits):.0f}-{max(hits):.0f} ms")
if miss:
    print(f"miss {len(miss)}: {min(miss):.0f}-{max(miss):.0f} ms")
