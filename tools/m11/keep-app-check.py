#!/usr/bin/env python3
"""Reads a keep-app-run.sh run: the windows and records each step logged, and whether they agree. Usage: keep-app-check.py RUN_DIR"""
import json
import sys

R = sys.argv[1]
bad = []
def load(phase):
    try:
        return {e["step"]: e for e in json.load(open(f"{R}/{phase}/receipt.json"))["composeLog"]}, json.load(open(f"{R}/{phase}/receipt.json"))["composeLog"]
    except FileNotFoundError:
        bad.append(f"{phase}: no receipt, it did not end by itself")
        return {}, []
first, _ = load("first")
relaunch, log = load("relaunch")
def rec(d, s): return json.loads(d[s]["record"]) if s in d and d[s].get("record") else None
def same(a, b, label, ignore=()):
    if a is None or b is None: bad.append(f"{label}: missing"); return
    for k in set(a) | set(b):
        if k in ignore: continue
        if a.get(k) != b.get(k): bad.append(f"{label}: {k} {a.get(k)} -> {b.get(k)}")
def want(d, s, key, value):
    if s not in d: bad.append(f"{s}: missing"); return
    if d[s].get(key) != value: bad.append(f"{s}: {key} {d[s].get(key)}, wanted {value}")
want(first, "closed", "windows", 0); want(first, "still here", "windows", 0); want(first, "still here", "visible", 0)
want(first, "reopened", "windows", 1); want(first, "reopened again", "windows", 1)
same(rec(first, "before close"), rec(first, "reopened"), "dock reopen")
if first.get("before close", {}).get("order") != first.get("reopened", {}).get("order"): bad.append("dock reopen: column order")
want(first, "closed for quit", "windows", 0)
for s, w in (("closed while moving", 0), ("back after moving", 1), ("closed in a mode flight", 0), ("back after a mode flight", 1), ("closed with settings open", 0), ("back with settings open", 1), ("settings closed", 1)):
    if s in first: want(first, s, "windows", w); print(f"{s:26} windows {first[s].get('windows')} visible {first[s].get('visible')} {first[s].get('settings', '')}")
if first.get("before quit", {}).get("order") != relaunch.get("relaunched", {}).get("order"): bad.append("relaunch: column order")
same(rec(first, "before quit"), rec(relaunch, "relaunched"), "⌘Q with no window, relaunch")
want(relaunch, "closed for cmd-n", "windows", 0)
want(relaunch, "cmd-n", "windows", 1)
n = rec(relaunch, "cmd-n")
if not n or not n.get("composingNew"): bad.append(f"cmd-n: not a new chat: {n}")
d = rec(relaunch, "draft typed")
if not d or d.get("draft") != "draft": bad.append(f"draft typed: {d and d.get('draft')}")
same(rec(relaunch, "draft typed"), rec(relaunch, "draft back"), "draft back")
for s in ("before close", "before quit", "relaunched", "cmd-n", "draft back"):
    src = first if s in first else relaunch
    print(f"{s:16} windows {src.get(s, {}).get('windows')} key {src.get(s, {}).get('key')} order {src.get(s, {}).get('order')} {src.get(s, {}).get('record', '')[:200]}")
cycles = [e for e in log if e.get("step") == "cycle"]
if cycles:
    print("no window cpu", round(relaunch["no window cpu"]["cpu"] * 100, 2), "% of one core")
    print("footprint MiB", {e["cycle"]: round(e["footprint"], 1) for e in cycles if e["cycle"] in (1, 5, 10, 15, 20)})
    if any(e["windows"] != 1 for e in cycles): bad.append("a cycle did not end with one window")
print(len(bad), "problems")
for b in bad: print(" ", b)
sys.exit(1 if bad else 0)
