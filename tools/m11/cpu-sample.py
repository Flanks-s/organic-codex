#!/usr/bin/env python3
# Idle cost: WindowServer's and the test app's CPU, once a second from top, each sample stamped with CLOCK_UPTIME_RAW (the clock
# of CACurrentMediaTime, so of the receipt's `t`). Waits up to 30 s for a build/OrganicShell*.app instance (CPU_APP_PATTERN for
# another path), samples until it
# quits or SECONDS pass. top's first sample has no interval behind it and is dropped.
# cpu-sample.py OUT.json SECONDS
# cpu-sample.py --window OUT.json FROM TO    mean / median / max of the samples whose stamp is in [FROM, TO] (receipt clock)
import json, os, re, subprocess, sys, time

def now():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)

def pid_of(pattern):
    out = subprocess.run(["pgrep", "-n", "-f", pattern], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None

if sys.argv[1] == "--window":
    samples = json.load(open(sys.argv[2])); lo, hi = float(sys.argv[3]), float(sys.argv[4])
    for key in ("app", "windowServer"):
        v = sorted(s[key] for s in samples if lo <= s["t"] <= hi and s.get(key) is not None)
        if v:
            print(f"{key}: n {len(v)}, mean {sum(v) / len(v):.1f}%, median {v[len(v) // 2]:.1f}%, max {v[-1]:.1f}%")
        else:
            print(f"{key}: no samples in the window")
    sys.exit(0)

out, seconds = sys.argv[1], int(sys.argv[2])
deadline = now() + 30
# CPU_APP_PATTERN: the pgrep pattern of the app (the MBA lane runs copies under labs/apps).
pattern = os.environ.get("CPU_APP_PATTERN", "build/[O]rganicShell[^/]*.app/Contents/MacOS/OrganicShell")
while (app := pid_of(pattern)) is None and now() < deadline:
    time.sleep(0.2)
ws = pid_of("/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer")
if app is None or ws is None:
    sys.exit(f"no app ({app}) or WindowServer ({ws})")
top = subprocess.Popen(["top", "-l", str(seconds + 1), "-s", "1", "-stats", "pid,cpu", "-pid", str(ws), "-pid", str(app)],
                       stdout=subprocess.PIPE, text=True, bufsize=1)
samples, cur, first = [], None, True
for line in top.stdout:
    if line.startswith("Processes:"):
        if cur is not None and not first:
            samples.append(cur)
        if cur is not None:
            first = False
        cur = {"t": now(), "app": None, "windowServer": None}
        continue
    m = re.match(r"\s*(\d+)\s+([\d.]+)", line)
    if m and cur is not None:
        pid, cpu = int(m.group(1)), float(m.group(2))
        if pid == app: cur["app"] = cpu
        if pid == ws: cur["windowServer"] = cpu
if cur is not None and not first:
    samples.append(cur)
json.dump(samples, open(out, "w"))
print(f"{len(samples)} samples, app pid {app}, WindowServer pid {ws}")
