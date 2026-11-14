# Reads an exported Time Profiler table (xctrace export … table[@schema="time-profile"]) and lists every stretch the main
# thread was sampled without a break (gap ≤ 2.5 ms) for longer than MIN_MS, with the frames most of its samples went
# through: the shared trunk first, then the deeper frames that took at least 15 % of the stretch.
# python3 main-busy.py time-profile.xml [MIN_MS]
import sys, collections
import xml.etree.ElementTree as ET

path = sys.argv[1]; min_ms = float(sys.argv[2]) if len(sys.argv) > 2 else 80
ids = {}
def resolve(e):
    if e is None: return None
    if "ref" in e.attrib: return ids.get(e.attrib["ref"], e)
    return e
def index(e):
    for sub in e.iter():
        if "id" in sub.attrib: ids[sub.attrib["id"]] = sub

samples = []
for _, row in ET.iterparse(path, events=("end",)):
    if row.tag != "row": continue
    index(row)
    t = thread = stack = None
    for child in list(row):
        c = resolve(child)
        if c.tag == "sample-time": t = int(c.text) / 1e6
        elif c.tag == "thread": thread = c.attrib.get("fmt", "")
        elif c.tag in ("backtrace", "tagged-backtrace"):
            # A tagged-backtrace holds its frames directly in current Instruments, or wraps one backtrace in older ones.
            bt = resolve(c.find("backtrace")) if c.find("backtrace") is not None else c
            frames = []
            for f in (bt if bt is not None else []):
                f = resolve(f)
                if f.tag == "frame": frames.append(f.attrib.get("name", "?"))
            stack = frames
    if t is not None and thread and "Main Thread" in thread and stack:
        samples.append((t, stack))
samples.sort()
print(f"main-thread samples {len(samples)}")
runs, cur = [], []
for s in samples:
    if cur and s[0] - cur[-1][0] > 2.5:
        runs.append(cur); cur = []
    cur.append(s)
if cur: runs.append(cur)
t0 = samples[0][0] if samples else 0
long = [r for r in runs if r[-1][0] - r[0][0] >= min_ms]
print(f"busy stretches ≥ {min_ms:.0f} ms: {len(long)}")
for r in long:
    n = len(r); dur = r[-1][0] - r[0][0]
    counts = collections.Counter()
    for _, st in r:
        for name in set(st): counts[name] += 1
    print(f"\n== {(r[0][0]-t0)/1000:8.3f} s  {dur:6.1f} ms  {n} samples")
    # leaf-first stacks: xctrace lists the leaf first
    shown = 0
    for name, c in sorted(counts.items(), key=lambda kv: -kv[1]):
        if c / n < 0.15 or shown >= 40: break
        print(f"  {100*c/n:5.1f}%  {name[:150]}")
        shown += 1
