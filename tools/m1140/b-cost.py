"""Fresh-process B costs, unchanged r3c metrics, per-sample 2x caps (#218)."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time
from importlib.util import spec_from_file_location, module_from_spec

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("bcheck", ROOT / "tools/m1140/check.py")
helper = module_from_spec(spec); spec.loader.exec_module(helper)
LIMITS = {"cold/firstTexture": 120.0, "cold/firstHD": 200.0, "warm/firstHD": 150.0,
          "cold-close/released": 20.0, "warm-close/released": 20.0}


def actual_violations(record):
    """Keep real limits effective even during the deliberately lowered-cap negative."""
    if record["scale"] != 2: return []
    failures = []
    for index, row in enumerate(record["samples"]):
        for key, limit in LIMITS.items():
            kind, metric = key.split("/")
            if row["kind"] != kind: continue
            value = row["seconds"].get(metric)
            if value is None or not math.isfinite(value) or value < 0 or value * 1000 > limit:
                failures.append({"sample": index, "metric": key, "seconds": value, "limitMS": limit})
        if row["kind"] in {"cold", "warm"} and row.get("ready") is not True:
            failures.append({"sample": index, "metric": row["kind"] + "/ready", "value": row.get("ready")})
        if row["kind"] in {"cold-close", "warm-close"}:
            state = row.get("releaseState", {})
            if any(state.get(k) != 0 for k in ["HD", "imageTasks", "phaseJobs", "phasePending"]):
                failures.append({"sample": index, "metric": row["kind"] + "/releaseState", "value": state})
    if not isinstance(record.get("peakHD"), int) or not 0 <= record["peakHD"] <= 16 * 1024 * 1024:
        failures.append({"metric": "peakHD", "value": record.get("peakHD"), "limitBytes": 16 * 1024 * 1024})
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=["positive", "negative", "restored"], default="positive")
    args = parser.parse_args()
    item = Path(os.environ["OC_ITEM_DIR"]); job = os.environ["OC_JOB"]
    out = Path(os.environ["OUT"]) / "m1140-b-cost" / (args.case + "-" + job)
    out.mkdir(parents=True, exist_ok=True)
    package = item / "m1140-b-cost-package"
    started = time.monotonic()
    deadline = started + min(1150, float(os.environ.get("M1140_B_BUDGET", "1150")))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", ORGANIC_BODY_CACHE_ROOT=str(item / "m1140-cost-cache"))
    sources = sorted((ROOT / "Sources/OrganicShell/Panels").glob(
            "*.swift")) + [ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"]
    fingerprint = lambda: {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    receipt = {"case": args.case, "job": job, "sourceHashes": fingerprint(), "buildExit": None,
               "runExits": [], "checks": 0, "failures": [], "actualViolations": [], "stopCondition": False,
               "checkMainSHA256": hashlib.sha256((ROOT / "tools/m1140/PanelsBCostMain.swift").read_bytes()).hexdigest(),
               "runnerSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "bodyResourcesSHA256": hashlib.sha256((
                       ROOT / "Sources/OrganicShell/BodyPresentation/BodyResources.swift").read_bytes()).hexdigest()}
    records = []
    try:
        command = [sys.executable, "tools/m11/check_package.py", "--root", str(ROOT), "--package", str(package),
                   "--body-assets", str(item / "m1140-check-bodies"), "--add", "tools/m1140/PanelsBCostMain.swift",
                       "--name", "M1140PanelCosts"]
        code = helper.run(command, out / "prepare.log", deadline, env)
        if code: return code
        if args.case == "negative":
            path = package / "Sources/Check/PanelsBCostMain.swift"
            text = path.read_text(encoding="utf-8")
            old, new = "static let coldHDCapMS = 200.0", "static let coldHDCapMS = 0.000001"
            assert text.count(old) == 1
            if path.is_symlink(): path.unlink()
            path.write_bytes(text.replace(old, new).encode("utf-8"))
            receipt.update(expectedCategory="cost.cap.cold-HD",
                mutatedMainSHA256=hashlib.sha256(path.read_bytes()).hexdigest())
        receipt["buildExit"] = helper.run(["swift", "build", "--package-path", str(package), "-c", "debug", "-j", "4"],
            out / "build.log", deadline, env)
        if receipt["buildExit"]: return receipt["buildExit"]
        plan = [(2, 0)] if args.case == "negative" else [(scale, index) for scale in [1, 2] for index in range(5)]
        for scale, index in plan:
            path = out / ("s%d-%d.json" % (scale, index))
            code = helper.run([str(package / ".build/debug/Check"), str(scale), str(path)], out / (path.stem + ".log"),
                deadline, env)
            receipt["runExits"].append(code)
            record = json.loads(path.read_text(encoding="utf-8")); records.append(record)
            receipt["checks"] += record["checks"]; receipt["failures"].extend(record["failures"])
            violations = actual_violations(record)
            if violations:
                receipt["actualViolations"].append({"file": path.name, "violations": violations})
                receipt["stopCondition"] = True
                return 1
            if args.case == "negative":
                receipt["validNegative"] = code == 1 and bool(record["failures"]) and all(f.startswith(
                        "cost.cap.cold-HD") for f in record["failures"])
                receipt["onlyExpectedCategory"] = all(f.startswith("cost.cap.") for f in record["failures"])
                return 0 if receipt["validNegative"] else 2
            if code or record["failures"]:
                receipt["stopCondition"] = any(f.startswith("cost.cap.") for f in record["failures"])
                return code or 1
        assert len({r["pid"] for r in records}) == 10
        for scale in [1, 2]:
            counts = {kind: sum(row["kind"] == kind for r in records if r["scale"] == scale for row in r["samples"])
                      for kind in ["cold", "warm", "cold-close", "warm-close"]}
            assert counts == {"cold": 5, "warm": 15, "cold-close": 5, "warm-close": 15}, counts
        return 0
    finally:
        groups = {}
        for record in records:
            for row in record["samples"]:
                for metric, value in row["seconds"].items():
                    groups.setdefault("%sx/%s/%s" % (record["scale"], row["kind"], metric), []).append(value * 1000)
        summary = {}
        for key, raw in groups.items():
            ordered = sorted(raw)
            summary[key] = {"n": len(raw), "p50_ms": ordered[(len(ordered)-1)//2],
                            "p90_ms": ordered[min(len(ordered)-1, int(len(ordered)*0.9))], "max_ms": max(raw),
                                "raw_ms": raw}
        (out / "summary.json").write_bytes((json.dumps({"latencyGate": {"scale": 2, "eachSample": True,
                "limitsMS": LIMITS, "HDBytes": 16 * 1024 * 1024},
            "freshProcesses": len(records), "costs": summary, "records": records,
            "peakHD": max((r["peakHD"] for r in records), default=None),
            "peakSprite": max((r["peakSprite"] for r in records), default=None),
            "peakMap": max((r["peakMap"] for r in records), default=None)}, indent=2) + "\n").encode("utf-8"))
        receipt["sourceUnchanged"] = receipt["sourceHashes"] == fingerprint()
        receipt["seconds"] = time.monotonic() - started
        (out / "receipt.json").write_bytes((json.dumps(receipt, indent=2) + "\n").encode("utf-8"))
        print(json.dumps({k: v for k, v in receipt.items() if k != "sourceHashes"}), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
