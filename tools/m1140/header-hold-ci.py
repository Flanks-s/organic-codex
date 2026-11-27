"""Standalone Header hold contract check for CI (#357): positive run plus four private negatives.

Compiles Island/HeaderIslandHold.swift with tools/m1140/HeaderHoldCheckMain.swift (no app target).
Each negative edits a temporary copy and must fail only its own category. Prints "N checks".
"""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/OrganicShell/Island/HeaderIslandHold.swift"
MAIN = ROOT / "tools/m1140/HeaderHoldCheckMain.swift"
# Same four mutations as the lane's header-hold-check.py (r9/r10): name -> (old, new, expected category).
NEGATIVES = {
    "boolean": ("entries.remove(at: index)",
                "entries.removeAll { $0.token.role == token.role }", "hold.count"),
    "restore-others": ("apply(token.role, writes: entry.writes)",
                       "for (role, fields) in originals {\n"
                       "            for (write, pose) in fields {"
                       " host?.headerHoldApply(pose, role: role, write: write) }\n"
                       "        }\n        apply(token.role, writes: entry.writes)", "hold.release"),
    "dispose-held": ("entries.removeAll() // Hold.invalidate",
                     "if reason != .disposed { entries.removeAll() } // Hold.invalidate", "hold.dispose"),
    "stale-release": ("guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }",
                      "guard let index = entries.firstIndex(where: {\n"
                      "            $0.token.role == token.role && $0.token.holder == token.holder\n"
                      "        }) else { return false }", "hold.stale"),
}


def run(name, source_text, out):
    work = out / name
    work.mkdir(parents=True, exist_ok=True)
    copy = work / SOURCE.name
    copy.write_text(source_text, encoding="utf-8")
    binary = work / "hold-check"
    # The check reads the check-build-only findings ledger, as the lane's P3 package does (-D CHECK_PACKAGE_WHOLE_TREE).
    build = subprocess.run(["swiftc", "-parse-as-library", "-D", "CHECK_PACKAGE_WHOLE_TREE",
                            str(copy), str(MAIN), "-o", str(binary)])
    if build.returncode != 0:
        return None
    subprocess.run([str(binary), str(work)])
    return json.loads((work / "report.json").read_text(encoding="utf-8"))


def main():
    out = Path(sys.argv[1])
    original = SOURCE.read_text(encoding="utf-8")
    results = {"positive": run("positive", original, out)}
    ok = results["positive"] is not None and not results["positive"]["failures"]
    for name, (old, new, category) in NEGATIVES.items():
        if original.count(old) != 1:
            print(f"FAIL: negative {name} anchor not unique")
            ok = False
            continue
        report = run(name, original.replace(old, new), out)
        results[name] = report
        hit = report is not None and report["failures"] and set(report["failures"]) == {category}
        print(f"negative {name}: {'only ' + category if hit else 'FAIL'}")
        ok = ok and bool(hit)
    (out / "summary.json").write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
    checks = sum(r["checks"] for r in results.values() if r)
    print(f"{checks} checks; positive failures: {results['positive'] and results['positive']['failures']}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
