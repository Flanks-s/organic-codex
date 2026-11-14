#!/usr/bin/env python3
# M11.31 side-by-side: per key press of a recorded mode run (made with INPUT_SYNC=1), what the user sees, from the video
# mapped onto the receipt's clock by sync-offset.py:
#   first moved frame   first recorded frame after the key with a channel change of 16 or more;
#   content start       the log's content event after the key (ModeContentFadeStart, or the phases in SBS_CONTENT);
#   settle              last frame with 50+ changed pixels before the next key or key + 2.5 s (quiet runs only: in a
#                       streaming run the text keeps changing, so this is the log's ModeFlightEnd instead);
#   largest frame       the most pixels changed by more than 64 levels in one frame (a hard cut moves many that far, a
#                       fade step few) between the key and the next key or + 2.5 s, and that frame's pixels over 8;
#   stalls              main-thread gaps over 50 ms and the largest, from the receipt, between the first and last key.
#   flight tick         the log's first flight display-link callback after the key (FlightFirstDisplayLink);
#   content frames      the first two recorded frames at or after the content event, with their pixels over 64 and over 8
#                       (on the atomic side the swap itself).
# sbs-table.py RUN_DIR [--quiet] [--json]
import json, os, re, subprocess, sys

run = sys.argv[1]; quiet = "--quiet" in sys.argv
here = os.path.dirname(os.path.abspath(__file__))
sync = json.loads(subprocess.run([sys.executable, os.path.join(here, "sync-offset.py"), run, "--json"],
                                 capture_output=True, text=True).stdout or "{}")
if "offset" not in sync:
    sys.exit(f"{run}: no sync offset")
off = sync["offset"]
r = json.load(open(os.path.join(run, "app", "receipt.json")))
ev = r["modeSwitchLog"]["events"]; log = r.get("composeLog", [])
content = os.environ.get("SBS_CONTENT", "ModeContentFadeStart").split(",")
cache = os.path.join(run, "frames-all.txt")
if not os.path.exists(cache):
    # BAND_BIN: a swiftc -O build of band-changes.swift; the interpreter takes most of an hour on a 70 s 2× recording.
    tool = [os.environ["BAND_BIN"]] if os.environ.get("BAND_BIN") else ["swift", os.path.join(here, "band-changes.swift")]
    out = subprocess.run(tool + [os.path.join(run, "rec.mov"), "0", "820"],
                         capture_output=True, text=True).stdout
    open(cache, "w").write(out)
frames = []
for line in open(cache):
    p = line.split()
    if len(p) >= 5 and p[1] == "max":
        frames.append((float(p[0]), int(p[2]), int(p[4]), int(p[-1]) if p[-2] == "over64" else 0))
keys = [e for e in ev if e["phase"] == "ModeContentKey"]
rows = []
for i, k in enumerate(keys):
    kv = k["time"] - off
    end = min(kv + 2.5, keys[i + 1]["time"] - off if i + 1 < len(keys) else 1e9)
    window = [f for f in frames if kv < f[0] <= end]
    first = next((f for f in window if f[1] >= 16), None)
    c = next((e for e in ev if e["phase"] in content and k["time"] < e["time"] <= end + off), None)
    if quiet:
        moving = [f for f in window if f[2] >= 50]
        settle = (moving[-1][0] - kv) * 1000 if moving else None
    else:
        fe = next((e for e in ev if e["phase"] == "ModeFlightEnd" and k["time"] < e["time"] <= end + off), None)
        settle = (fe["time"] - k["time"]) * 1000 if fe else None
    big = max(window, key=lambda f: (f[3], f[2]), default=None)
    tick = next((e for e in ev if e["phase"] == "FlightFirstDisplayLink" and k["time"] < e["time"] <= end + off), None)
    cf = [f for f in frames if c and f[0] >= c["time"] - off][:2]
    rows.append({"to": re.search(r"requested=(\w+)", k["detail"]).group(1), "keyVideo": round(kv, 3),
                 "firstMovedMS": round((first[0] - kv) * 1000, 1) if first else None,
                 "contentStartMS": round((c["time"] - k["time"]) * 1000, 1) if c else None,
                 "settleMS": round(settle, 1) if settle is not None else None,
                 "largestFramePx": big[3] if big else 0, "largestFrameOver8": big[2] if big else 0, "largestFrameAtMS": round((big[0] - kv) * 1000, 1) if big else None,
                 "flightTickMS": round((tick["time"] - k["time"]) * 1000, 1) if tick else None,
                 "contentFrames": [{"atMS": round((f[0] - kv) * 1000, 1), "px64": f[3], "px8": f[2]} for f in cf],
                 "nextKeyMS": round((keys[i + 1]["time"] - k["time"]) * 1000) if i + 1 < len(keys) else None})
t0, t1 = keys[0]["time"], keys[-1]["time"] + 2.5
st = [e["ms"] for e in log if e.get("step") == "stall" and t0 <= e["t"] <= t1]
summary = {"run": run, "offset": off, "keys": len(keys), "stallsOver50": sum(s > 50 for s in st), "maxStallMS": max(st, default=0)}
if "--json" in sys.argv:
    print(json.dumps({"summary": summary, "rows": rows}))
else:
    print(f"{run}: rec = log - {off:.4f}; {len(keys)} keys; stalls over 50 ms {summary['stallsOver50']}, largest {summary['maxStallMS']:.1f} ms")
    print(f"  {'to':8s} {'video':>8s} {'first':>7s} {'tick':>6s} {'content':>8s} {'settle':>7s} {'px >64':>8s} {'px >8':>8s} {'at':>7s} {'next key':>9s}  content frames (at ms px>64/px>8)")
    for x in rows:
        f = lambda v: "—" if v is None else f"{v:.0f}"
        cfs = "  ".join(f"{c['atMS']:.0f} {c['px64']}/{c['px8']}" for c in x["contentFrames"])
        print(f"  {x['to']:8s} {x['keyVideo']:8.3f} {f(x['firstMovedMS']):>7s} {f(x['flightTickMS']):>6s} {f(x['contentStartMS']):>8s} {f(x['settleMS']):>7s} "
              f"{x['largestFramePx']:>8d} {x['largestFrameOver8']:>8d} {f(x['largestFrameAtMS']):>7s} {f(x['nextKeyMS']):>9s}  {cfs}")
