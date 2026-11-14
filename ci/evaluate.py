#!/usr/bin/env python3
"""Verdict for one CI gates run (infra lane, Claude, 2026-11-07). Copied into each ci/* snapshot as ci/evaluate.py.

evaluate.py OUT_DIR BASELINE.json   -> prints a table, writes OUT_DIR/verdict.json (+ GitHub step summary),
                                       exits 1 only if a suite that counts on CI is worse than the HEAD baseline.

What counts on CI (tools/mac/README.md, "GitHub Actions"):
  selftest              findings outside retained-animation-visibility (that check needs a real display)
  island-layer, long-conversation, window-lifetime, no-window      exit status
  column-work           functional findings; "<= N ms" timing findings never count on a VM
  m10-columns           FINDING lines by kind, against the HEAD baseline counts
  m10-columns-reduced   the same suite with Reduce Motion and Reduce Transparency on (#173), its own baseline entry;
                        m10-columns-reduce-motion / -reduce-transparency (one switch each) are informational
  core                 FINDING lines of the Core suite (tools/m11/core-4954-check.py), against the baseline (#156)
  component-KIND       tools/m11/component-check.py (#186/#195): FINDING/FAIL lines, plus any findings its COMPONENT
                       total counts beyond them; no COMPONENT total line is a crash
  m101-columns, pulse   informational only (m101 crashes in the VM; pulse needs the board fixtures)
Any finding kind not in the baseline, or more of a kind than the baseline has, makes a counted suite worse.

A suite judged by its findings must also show that it ran (#152, 11-10: m11-1-check stopped compiling with M11.44, exited
1 after 46 s without running one check, and "0 FAIL lines" read as a pass against a baseline of 15). Every such suite
prints a final total line ("353 checks", "15 scenarios"); crash_reason() below calls a run without one a crash, and a
crash is a failure whether or not the suite has a baseline. The table shows the total, so an empty run is visible.
"""
import json, os, re, sys

SELFTEST_ENV_ONLY = {"retained-animation-visibility"}
TIMING = re.compile(r"<=\s*\d+(\.\d+)?\s*ms")
INFO_ONLY = {"m101-columns", "pulse", "m10-columns-reduce-motion", "m10-columns-reduce-transparency"}
EXIT_ONLY = {"island-layer", "long-conversation", "window-lifetime", "no-window"}
# The final total line of each suite that always prints one. Sub-totals earlier in a log ("Island layers: 304 checks"
# inside column-work) do not count: a suite that dies after them has still not finished.
TOTALS = {
    "column-work": re.compile(r"^COLUMN WORK (\d+) checks\b", re.M),
    "m10-columns": re.compile(r"^M10 columns: (\d+) checks\b", re.M),
    "m10-columns-reduced": re.compile(r"^M10 columns: (\d+) checks\b", re.M),
    "m11-1-check": re.compile(r"^M11-1: (\d+) checks\b", re.M),
    "core": re.compile(r"^CORE_SELFTEST: (\d+) checks\b", re.M),
}
# #186/#195: component-check.py's own final line; it prints "did not complete" (no total) when the harness died.
COMPONENT_LINE = re.compile(r"^COMPONENT ([a-z0-9-]+): (\d+) checks, (\d+) findings$", re.M)
for _kind in ("native", "settings", "overlay", "sheets", "sheets-m101", "debug", "tools", "header-ax", "split",
              "split-model", "normie-motion", "dock-switches", "dock-gaussian"):
    TOTALS["component-" + _kind] = re.compile(r"^COMPONENT %s: (\d+) checks\b" % re.escape(_kind), re.M)
UNLABELLED = "finding without a FINDING/FAIL line (from the COMPONENT total)"
SELFTEST_TOTAL = re.compile(r"^selftest (\d+)x: (\d+) scenarios\b", re.M)
SELFTEST_SCALES = {"1", "2"}  # scripts/selftest.sh runs both scales; each prints its own total
# Command suites (--suite-cmd): the last total they print, as text ("824 checks") or in a JSON receipt ("checks": 1730).
GENERIC_TOTAL = re.compile(r'\b(\d+) checks\b|"checks"\s*:\s*(\d+)')


def norm(line):
    return re.sub(r"\d+(\.\d+)?", "N", line.strip())


def check_total(suite, text):
    """How many checks the suite says it ran, from its final total line; None when there is no such line."""
    if suite == "selftest":
        per_scale = {m.group(1): int(m.group(2)) for m in SELFTEST_TOTAL.finditer(text)}
        if not SELFTEST_SCALES <= set(per_scale):
            return None  # a scale that never printed its total did not finish
        return sum(per_scale[s] for s in SELFTEST_SCALES)
    found = [next(g for g in m.groups() if g) for m in (TOTALS.get(suite) or GENERIC_TOTAL).finditer(text)]
    return int(found[-1]) if found else None


def crash_reason(suite, code, text):
    """Why a finding-judged suite gave no answer, or None when it did. A crashed suite has no findings to compare.

    - an exit status other than 0 (clean) or 1 (findings);
    - a suite with a known total line that did not print it, or printed 0, whatever its exit status;
    - any other (command) suite that exits non-zero without a total above 0: without the total there is no telling
      "found something" from "never ran". Command suites that pass may stay silent."""
    if code not in (0, 1):
        return "exit %d" % code
    total = check_total(suite, text)
    if total:
        return None
    if suite != "selftest" and suite not in TOTALS and code == 0:
        return None
    what = "no check total" if total is None else "0 checks"
    return "exit %d, %s" % (code, what)


def suite_text(out_dir, suite):
    """The suite's log plus its inner check.log (command suites that stop before printing their own log)."""
    text = ""
    for p in (os.path.join(out_dir, suite + ".log"), os.path.join(out_dir, suite, "check.log")):
        if os.path.exists(p):
            text += open(p, encoding="utf-8", errors="replace").read() + "\n"
    return text


def kinds_of(suite, text):
    """Finding kinds (normalized) that count for this suite, with their counts."""
    out = {}
    if suite.startswith("component-"):
        return component_kinds(suite, text)
    if suite == "selftest":
        for line in text.splitlines():
            if line.startswith("  ") and " · " in line:
                scenario = line.strip().split(" · ")[0]
                if scenario in SELFTEST_ENV_ONLY:
                    continue
                k = norm(" · ".join(line.strip().split(" · ")[:2]))
                out[k] = out.get(k, 0) + 1
        return out
    for line in text.splitlines():
        s = line.strip()
        if not (s.startswith("FINDING") or s.startswith("FAIL:")):  # FAIL: lines come from tools/m11 check entries
            continue
        if suite == "column-work" and TIMING.search(s):
            continue
        k = norm(s)
        out[k] = out.get(k, 0) + 1
    return out


# A harness summary line ("M1 verification: 2575 checks, 80 findings -> ..."); some harnesses list their findings
# right below it, indented by two spaces, instead of as FINDING/FAIL lines.
HARNESS_SUMMARY = re.compile(r"\b\d+ checks?,? \d+ (findings?|failures?)\b")


def component_kinds(suite, text):
    """component-check.py suites (#195): FINDING/FAIL lines, else the indented list under the harness summary; "<= N
    ms" timing findings never count on a VM. The COMPONENT total is authoritative: findings it counts beyond the
    listed ones still count, as one kind, instead of passing unseen."""
    labelled = [l.strip() for l in text.splitlines() if l.strip().startswith(("FINDING", "FAIL:"))]
    if not labelled:
        listing = False
        for line in text.splitlines():
            if HARNESS_SUMMARY.search(line) and not line.startswith(("COMPONENT ", " ")):
                listing = True
                continue
            if listing and line.startswith("  ") and line.strip():
                labelled.append(line.strip())
            else:
                listing = False
    out = {}
    for s in labelled:
        if TIMING.search(s):
            continue
        k = norm(s)
        out[k] = out.get(k, 0) + 1
    totals = [int(m.group(3)) for m in COMPONENT_LINE.finditer(text) if "component-" + m.group(1) == suite]
    extra = (totals[-1] if totals else 0) - len(labelled)
    if extra > 0:
        out[UNLABELLED] = extra
    return out


def main():
    out_dir, baseline_path = sys.argv[1], sys.argv[2]
    base = json.load(open(baseline_path, encoding="utf-8")) if os.path.exists(baseline_path) else {}
    rows = []
    for line in open(os.path.join(out_dir, "summary.tsv"), encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 3 and parts[1].lstrip("-").isdigit():
            rows.append((parts[0], int(parts[1]), float(parts[2])))
    verdict, worse_any = [], False
    for suite, code, secs in rows:
        text = suite_text(out_dir, suite)
        total = check_total(suite, text)
        if suite in INFO_ONLY:
            verdict.append({"suite": suite, "counts": False, "exit": code, "seconds": secs, "checks": total,
                            "status": "info"})
            continue
        if suite in EXIT_ONLY:
            ok = code == 0
            verdict.append({"suite": suite, "counts": True, "exit": code, "seconds": secs, "checks": total,
                            "status": "pass" if ok else "WORSE (exit %d)" % code})
            worse_any |= not ok
            continue
        # selftest / column-work / m10-columns (and any suite run by name): finding kinds against the baseline,
        # but only for a suite that ran. A crash is a failure with or without a baseline (#152).
        crashed = crash_reason(suite, code, text)
        if crashed:
            verdict.append({"suite": suite, "counts": True, "exit": code, "seconds": secs, "checks": total,
                            "status": "WORSE (crash: %s; nothing was compared)" % crashed})
            worse_any = True
            continue
        got = kinds_of(suite, text)
        if suite not in base:
            # A suite without a baseline yet only reports; `ci.sh baseline ITEM N` adds it once a run is reviewed.
            verdict.append({"suite": suite, "counts": False, "exit": code, "seconds": secs, "checks": total,
                            "status": "info (no baseline yet; %d finding line(s))" % sum(got.values())})
            continue
        allowed = base.get(suite, {})
        worse = {k: (allowed.get(k, 0), n) for k, n in got.items() if n > allowed.get(k, 0)}
        status = "pass" if not worse else "WORSE (%d kind(s) above baseline)" % len(worse)
        verdict.append({"suite": suite, "counts": True, "exit": code, "seconds": secs, "checks": total,
                        "status": status, "findings_counted": sum(got.values()), "baseline": sum(allowed.values()),
                        "worse": {k: {"baseline": b, "now": n} for k, (b, n) in worse.items()}})
        worse_any |= bool(worse)
    json.dump({"worse": worse_any, "suites": verdict}, open(os.path.join(out_dir, "verdict.json"), "w"), indent=1)
    lines = ["| suite | counts on CI | exit | seconds | checks run | verdict |", "| --- | --- | --- | --- | --- | --- |"]
    for v in verdict:
        lines.append("| %s | %s | %d | %.0f | %s | %s |" % (
            v["suite"], "yes" if v["counts"] else "no (info)", v["exit"], v["seconds"],
            "-" if v["checks"] is None else v["checks"], v["status"]))
    for v in verdict:
        for k, d in (v.get("worse") or {}).items():
            lines.append("")
            lines.append("- %s: `%s` baseline %d, now %d" % (v["suite"], k[:160], d["baseline"], d["now"]))
    table = "\n".join(lines)
    print(table)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write("## Offscreen gates (timings never count on CI)\n\n" + table + "\n")
    sys.exit(1 if worse_any else 0)


if __name__ == "__main__":
    main()
