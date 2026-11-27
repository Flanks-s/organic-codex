#!/usr/bin/env python3
"""Reads the receipt of a `--demo-input long-seq` run (App/InputRun.swift): for each step, the switch it caused and the
main-thread turns over 20 ms that followed it.

Usage: long-check.py RECEIPT.json [--stalls]   --stalls also lists every turn with its time after the step.
A switch's `compile` is the synchronous work before its first frame could be drawn. `hit` is whether it used the switch
prepared ahead. Injected events, not a real mouse: tracking areas don't fire, so hover cost is not in these numbers.
"""
import json
import sys

args = [a for a in sys.argv[1:] if not a.startswith("--")]
show = "--stalls" in sys.argv
r = json.load(open(args[0]))
log = r.get("composeLog", [])
steps = [e for e in log if str(e.get("step", "")).startswith("long ")]
stalls = [e for e in log if e.get("step") == "stall"]
switches = [s for s in r.get("switches", []) if "at" in s]

if not steps:
    sys.exit("no long-seq steps in this receipt")
print(f"{'step':18} {'items':>5} {'hit':>4} {'compile':>8} {'flush':>6} {'worst':>6} {'turns':>5}  key")
key_state = {e.get("step"): (e.get("state") or {}).get("key") for e in log}
groups = {}
for k, e in enumerate(steps):
    end = steps[k + 1]["t"] if k + 1 < len(steps) else e["t"] + 3
    s = next((x for x in switches if e["t"] <= x["at"] < end), None)
    inside = [x for x in stalls if e["t"] <= x["began"] < end]
    worst = max((x["ms"] for x in inside), default=0)
    hit = "" if s is None else ("yes" if s.get("prewarmed") else "no")
    compile_ms = "" if s is None else f"{s['compileMs']:.1f}"
    flush = "" if s is None else f"{s['flushMs']:.1f}"
    name = e["step"][5:]
    print(f"{name:18} {e.get('items', ''):>5} {hit:>4} {compile_ms:>8} {flush:>6} {worst:6.1f} {len(inside):5}")
    if show:
        for x in inside:
            print(f"    +{x['began'] - e['t']:.3f} s  {x['ms']:.1f} ms")
    group = name.rsplit("-", 1)[0] if name.rsplit("-", 1)[-1].isdigit() else name
    if s is not None:
        groups.setdefault(group, []).append(s["compileMs"])
print()
for group, values in groups.items():
    print(f"{group:18} compile {min(values):6.1f} - {max(values):6.1f} ms over {len(values)}")
print(f"turns over 20 ms: {len(stalls)}, worst {max((x['ms'] for x in stalls), default=0):.1f} ms")
print("load", r.get("liveCore", {}).get("shown"))
