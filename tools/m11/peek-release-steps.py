#!/usr/bin/env python3
"""peek-release (InputRun): for each variant, whether the Peek opened while the release was still springing, and the
Peek item's glass steps around the switch or reorder. A first-frame jump shows as the change's largest step being far
above the steps just before it. python3 peek-release-steps.py receipt.json"""
import json, sys, statistics

log = json.load(open(sys.argv[1])).get("composeLog", [])
for e in log:
    step = str(e.get("step", ""))
    if not step.startswith("peek-release.") or "glass" not in e:
        if step.startswith("peek-release.") and "skipped" in e: print(step, "skipped:", e["skipped"])
        continue
    g, at = e["glass"], e.get("changeAt", 0)
    steps = [(b[0], max(abs(b[k] - a[k]) for k in range(1, 5))) for a, b in zip(g, g[1:])]
    before = [s for t, s in steps if at - 0.3 <= t < at]
    after = [(t, s) for t, s in steps if at <= t < at + 0.12]
    base = statistics.median(before) if before else 0
    worst = max(after, key=lambda x: x[1]) if after else (0, 0)
    opened = e.get("peekOpened", -1)
    # Auto's release starts with leaving Split and lasts about the orb's spring; a Peek opened inside it takes the glass over.
    leave, spring = e.get("leaveAt", 0), e.get("orbSpring", 0)
    inside = leave <= opened < leave + spring
    print(f"{step}: orb {e.get('peek')} (Peek shows {e.get('shown')}) opened {opened:.3f}s after let-go, "
          f"{opened - leave:.3f}s after leaving Split, {'inside' if inside else 'outside'} the {spring:.3f}s release; "
          f"still orb {e.get('stillOrb')}; change at {at:.3f}s: "
          f"largest step {worst[1]:.2f} pt at +{worst[0] - at:.3f}s, steps before it median {base:.2f} pt; samples {len(g)}")
