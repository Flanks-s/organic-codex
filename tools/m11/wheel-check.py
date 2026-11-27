#!/usr/bin/env python3
"""Reads the receipt of a `--demo-input long-wheel` run (App/InputRun.swift widthTrial): one line per change of width with a wheel step.

Usage: wheel-check.py RECEIPT.json
edge<N: seconds after the commit until every column's edge stays within N pt of its target. shown: the real transcript visible.
settle: scene settled. step at: when the step was posted, what the hit test found. answered: when the offset first moved after that, by
how far from the end the reader ended up (a step is about 30 pt). LOST: the step changed nothing. slide: the settle slide's distance, picture: the offset the moving picture was taken at against the offset at settle.
Injected events, not a real mouse.
"""
import json
import sys

r = json.load(open(sys.argv[1]))
log = [e for e in r.get("composeLog", []) if str(e.get("step", "")).startswith("wheel ")]
if not log:
    sys.exit("no wheel trials in this receipt")
print(f"{'kind':12} {'at':>4} {'items':>5} {'pre':>3} {'comp':>6} {'dur':>5} {'e<8':>5} {'e<2':>5} {'e<1':>5} {'e<.5':>5} {'shown':>5} {'settle':>6} {'answered':>9} {'by':>6} {'slide':>6} {'pict':>7} {'settleY':>7} hit")
groups = {}
for e in log:
    reached = {a: b for a, b in e["reached"]}
    after = [m for m in e["moves"] if m[0] >= e["posted"]]
    # A step reads up by about 30 pt and stays: height refinement moves the offset too, keeping the text where it is, so `fromEnd` says
    # whether the step survived. Lost means it never moved the reader away from the end.
    answered = after[0][0] if after and e["fromEnd"] > 1 else None
    by = e["fromEnd"]
    pict = e["picture"][0] if e["picture"] else float("nan")
    settle_y = e["atSettle"][0] if e["atSettle"] else float("nan")
    print(f"{e['kind']:12} {e['delay']:4.2f} {e['items']:5} {'y' if e['prewarmed'] else 'n':>3} {e['compile']:6.1f} {e['duration']:5.2f} {reached.get(8.0, 0):5.2f} {reached.get(2.0, 0):5.2f} {reached.get(1.0, 0):5.2f} {reached.get(0.5, 0):5.2f} {e['shown']:5.2f} {e['settled']:6.2f} {(f'{answered:.2f}' if answered is not None else 'LOST'):>9} {by:6.1f} {e['slide']:6.1f} {pict:7.0f} {settle_y:7.0f} {e['hit'][:24]}")
    g = groups.setdefault(e["kind"], {"settle": [], "e1": [], "lost": 0, "n": 0, "first": [], "slide": []})
    g["n"] += 1
    g["settle"].append(e["settled"]); g["e1"].append(reached.get(1.0, 0)); g["slide"].append(abs(e["slide"]))
    if answered is None:
        g["lost"] += 1
    else:
        g["first"].append(answered)
print()
for k, g in groups.items():
    print(f"{k:12} n {g['n']:2}  edge<1 {min(g['e1']):.2f}-{max(g['e1']):.2f}  settle {min(g['settle']):.2f}-{max(g['settle']):.2f}  answered {('%.2f-%.2f' % (min(g['first']), max(g['first']))) if g['first'] else 'never'}  lost {g['lost']}  slide up to {max(g['slide']):.0f} pt")
