#!/usr/bin/env python3
"""Load rule for hitch-* timing runs, shared by every lane: #248 plus the #251/#252 exceptions (Claude, infra, 11-15).

#248: a run is valid when load1 is < 4 at the start and stays < 4 from the start until the recording ends + 25 s
(xctrace converting its ktrace afterwards is the tool's own load, recorded only). #217 (other jobs in the queue log)
and #239 (cool-down before the next run) are separate checks and unchanged.

#251 exception (DECISIONS ec0a6f6): about 7% of runs show one load sample at the moment the recording starts where a
few hundred threads are runnable for an instant (I-LOG d76e376: 319-551, back to 1-8 on the next sample). load1 has a
60 s time constant, so that instant keeps load1 >= 4 through the whole window although nothing else ran.
#252 (f6f4a25) adds the same at the moment the recording ends (bfs: n 350 at 38.0 s after xctrace was seen).
A run is NOT voided when, for each zone that holds a jump (n >= 12):
  1. the zone holds exactly one jump; zones: start = 0..4 s after xctrace is seen; end = 4 s either side of the
     estimated recording end (xctrace seen + RECORD_START_OFFSET_S + secs; the offset is where the three start jumps
     sat, 2.1-2.7 s);
  2. the sample after the jump has n < 12;
and 3. with the decaying tails of the excepted jumps taken out, load1 stays < 4 from the start to the window end.
Both zones may each hold one excepted jump. A jump in the middle of the recording (start zone end to end zone start)
or after the end zone gets no exception and counts as is (#248). Runs without xctraceSeen get no exception.

n is the runnable-thread count the kernel saw at a sample: macOS updates load1 every 5 s as
L_k = a*L_(k-1) + (1-a)*n with a = exp(-5/60), so n = (L_k - a*L_(k-1)) / (1-a) (a^m for m missed samples).
A jump's tail is taken out by replacing its n with the larger of its neighbours' n (the smaller correction).

Not retroactive: re-judging tools apply each exception only to jobs from its commit on (EFFECTIVE_STAMP per zone);
real-scene drivers on the MBA pass allow_exception=True, the src they run is what decides.
Python 3.9 compatible (runs on the MBA inside real-scene drivers).

CLI: hitch_load.py RUN_JSON... [--secs 35] [--fallback-start 8] [--all]   one verdict line per run.json
(--all: apply both exceptions regardless of the job's date, for replays).
"""
import json
import math
import re
import sys

A = math.exp(-5 / 60)
SPIKE_N = 12               # a sample with n >= this is a jump
ZONE_S = 4                 # start zone: 0..4 s after xctrace seen; end zone: estimated end +- 4 s
RECORD_START_OFFSET_S = 2.5  # recording start after xctrace is seen (start jumps at 2.1-2.7 s, I-LOG d76e376)
LIMIT = 4.0                # #248 load1 limit
TAIL_S = 25                # #248: the window runs to the recording end + 25 s
# Jobs whose id stamp (YYMMDD-HHMMSS) sorts at or after this get the exception for that zone.
EFFECTIVE_STAMP = {"start": "261115-1320", "end": "261115-1335"}
ZONE_LABEL = {"start": "开始", "end": "结束"}


def job_stamp(job):
    m = re.search(r"-(\d{6}-\d{6})-[a-z]{3}$", job or "")
    return m.group(1) if m else None


def exception_effective(job, zone="start"):
    s = job_stamp(job)
    return bool(s) and s >= EFFECTIVE_STAMP[zone]


def ticks(load):
    """Kernel load samples seen in a 0.5 s getloadavg series: (elapsed, load1) at every value change."""
    out = []
    for p in load:
        if not out or p["load1"] != out[-1][1]:
            out.append((p["elapsed"], p["load1"]))
    return out


def runnable(tk):
    """[(t, n, m)] for every tick after the first: implied runnable threads, m = kernel samples since the previous."""
    out = []
    for (t0, l0), (t1, l1) in zip(tk, tk[1:]):
        m = max(1, int(round((t1 - t0) / 5.0)))
        am = A ** m
        out.append((t1, (l1 - am * l0) / (1 - am), m))
    return out


def _allowed(allow_exception, zone):
    if isinstance(allow_exception, dict):
        return bool(allow_exception.get(zone))
    return bool(allow_exception)


def judge(load, initial_load, window_end, record_start=None, allow_exception=True, record_secs=35):
    """Verdict dict: valid, rule ('#248', '#251 例外（开始）', '#251 例外（结束）', '#251 例外（开始+结束）'),
    windowLoadMax, windowEnd, and spike (list of excepted jumps) when an exception was considered.
    allow_exception: True/False for both zones, or {"start": bool, "end": bool}."""
    win = [p["load1"] for p in load if p["elapsed"] <= window_end]
    wmax = max(win + [initial_load])
    out = {"valid": initial_load < LIMIT and wmax < LIMIT, "rule": "#248", "windowLoadMax": wmax, "windowEnd": window_end}
    if out["valid"] or initial_load >= LIMIT:
        return out
    zones_on = [z for z in ("start", "end") if _allowed(allow_exception, z)]
    if not zones_on:
        out["reason"] = "#251/#252 exceptions not effective for this job"
        return out
    if record_start is None:
        out["reason"] = "no recording start seen, no #251 exception"
        return out
    end_ref = record_start + RECORD_START_OFFSET_S + record_secs
    bounds = {"start": (record_start, record_start + ZONE_S), "end": (end_ref - ZONE_S, end_ref + ZONE_S)}
    tk = ticks(load)
    ns = runnable(tk)
    spikes = []
    for zone in zones_on:
        lo, hi = bounds[zone]
        jumps = [i for i, (t, n, m) in enumerate(ns) if lo <= t <= hi and n >= SPIKE_N]
        if not jumps:
            continue
        if len(jumps) > 1:
            out["reason"] = "%d jumps in the %s zone, the exception needs exactly one" % (len(jumps), zone)
            return out
        i = jumps[0]
        if i + 1 >= len(ns):
            out["reason"] = "no sample after the %s jump" % zone
            return out
        ts, n_s, m_s = ns[i]
        n_next = ns[i + 1][1]
        if n_next >= SPIKE_N:
            out["reason"] = "sample after the %s jump still n %.0f >= %d" % (zone, n_next, SPIKE_N)
            return out
        n_prev = ns[i - 1][1] if i > 0 else 0.0
        excess = (n_s - max(n_prev, n_next, 0.0)) * (1 - A ** m_s)
        spikes.append({"zone": zone, "t": round(ts, 1), "sinceXctraceSeen": round(ts - record_start, 1),
                       "n": round(n_s), "nextN": round(n_next), "_ts": ts, "_excess": excess})
    if not spikes:
        out["reason"] = "no jump in the start or end zone"
        return out
    corrected = [initial_load]
    for t, l in tk:
        if t > window_end:
            break
        c = l
        for s in spikes:
            if t >= s["_ts"]:
                c -= s["_excess"] * A ** int(round((t - s["_ts"]) / 5.0))
        corrected.append(c)
    cmax = max(corrected)
    for s in spikes:
        del s["_ts"], s["_excess"]
        s["correctedWindowLoadMax"] = round(cmax, 2)
    out["spike"] = spikes
    if cmax >= LIMIT:
        out["reason"] = "load1 without the jumps' tails still reaches %.2f" % cmax
        return out
    out.update(valid=True, rule="#251 例外（%s）" % "+".join(ZONE_LABEL[s["zone"]] for s in spikes))
    return out


def label(v):
    """Short text for judging output."""
    if v["rule"].startswith("#251 例外"):
        jumps = "; ".join("%s jump n=%d at +%.1f s, next n=%d" % (s["zone"], s["n"], s["sinceXctraceSeen"], s["nextN"])
                          for s in v["spike"])
        return "%s (%s; window load without them %.2f)" % (v["rule"], jumps, v["spike"][0]["correctedWindowLoadMax"])
    return "#248 %s (window load max %.2f%s)" % ("valid" if v["valid"] else "INVALID", v["windowLoadMax"],
                                             ("; " + v["reason"]) if v.get("reason") else "")


def tag(v):
    """Compact marker for comparison tables, empty unless an exception was used."""
    if not v["rule"].startswith("#251 例外"):
        return ""
    return " [%s %s]" % (v["rule"], ", ".join("n=%d next n=%d" % (s["n"], s["nextN"]) for s in v["spike"]))


def judge_run(rj, secs=35, fallback_start=8, allow_exception=None):
    """Judge a real-scene run.json row (keys load, initialLoad, xctraceSeen, job).
    allow_exception None: each zone by the job's id stamp (re-judging tools)."""
    start = rj.get("xctraceSeen")
    window = (start if start is not None else fallback_start) + secs + TAIL_S
    if allow_exception is None:
        allow_exception = {z: exception_effective(rj.get("job"), z) for z in ("start", "end")}
    return judge(rj["load"], rj["initialLoad"], window, start, allow_exception, secs)


if __name__ == "__main__":
    args = sys.argv[1:]
    secs, fb, allow = 35, 8, None
    if "--secs" in args:
        k = args.index("--secs"); secs = float(args[k + 1]); del args[k:k + 2]
    if "--fallback-start" in args:
        k = args.index("--fallback-start"); fb = float(args[k + 1]); del args[k:k + 2]
    if "--all" in args:
        args.remove("--all"); allow = True
    for f in args:
        rj = json.load(open(f))
        print("%s %s" % (rj.get("job") or f, label(judge_run(rj, secs, fb, allow))))
