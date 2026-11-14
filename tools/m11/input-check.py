#!/usr/bin/env python3
"""Reads the receipt of a `--demo-input` run (App/InputRun.swift) and lists what each path left behind.

Usage: input-check.py RECEIPT.json [--all] [--inactive]
Exit status 1 when any path left something or ran without a key window, or when the run did not finish.
--all also prints the clean paths.
Injected events, not a real mouse: the cursor never moves, so hover and `pressedMouseButtons` are not exercised.
"""
import json
import sys

# These paths lose key on purpose. Anywhere else a window that isn't key means the path did nothing (orbs can't be
# dragged), so its empty findings prove nothing.
LOSES_KEY = ("tear-resign.", "tear-desktop.", "tear-merge.", "island-layer")

args = [a for a in sys.argv[1:] if not a.startswith("--")]
show_all = "--all" in sys.argv
log = json.load(open(args[0])).get("composeLog", [])
paths = [e for e in log if "findings" in e and isinstance(e["findings"], list)]
done = next((e for e in log if e.get("step") == "done"), None)
skipped = [e for e in log if "skipped" in e and "step" in e and e["step"] != "done"]
# --inactive: a run that keeps away from the focus on purpose (long-real.sh, INPUT_INACTIVE). Its paths only click.
void = [] if "--inactive" in sys.argv else [e for e in paths if e.get("state", {}).get("key") is False and not e["step"].startswith(LOSES_KEY)]

bad = 0
for e in paths:
    s = e.get("state", {})
    if e["findings"]:
        bad += 1
        print(f"LEFT  {e['step']:22} {'; '.join(e['findings'])}")
    elif show_all:
        shown = " ".join(f"{str(t['id'])[:6]}:{t['ink']:.3f}" for t in e.get("transcripts", []) if t.get("full"))
        print(f"ok    {e['step']:22} order {','.join(x[:6] for x in s.get('order', []))} current {str(s.get('current', ''))[:6]} mode {s.get('mode')} ink {shown}")
for e in skipped:
    print(f"skip  {e['step']:22} {e['skipped']}")
for e in void:
    print(f"VOID  {e['step']:22} ran without a key window")
print(f"{len(paths)} paths, {bad} left something, {len(skipped)} skipped, {len(void)} void" + ("" if done else "; RUN DID NOT FINISH"))
sys.exit(1 if bad or void or not done else 0)
