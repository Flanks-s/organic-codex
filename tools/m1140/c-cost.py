"""Live-host costs using the unchanged B/#218 clocks, readiness and sample plan."""
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("panel_b_cost", ROOT / "tools/m1140/b-cost.py")
baseline = module_from_spec(spec); spec.loader.exec_module(baseline)


def main():
    item = Path(os.environ["OC_ITEM_DIR"]); job = os.environ["OC_JOB"]
    out = Path(os.environ["OUT"]) / "m1140-c-cost" / job
    out.mkdir(parents=True, exist_ok=True)
    package = item / "m1140-c-cost-package"
    started = time.monotonic(); deadline = started + min(1150, float(os.environ.get("M1140_C_BUDGET", "1150")))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", ORGANIC_BODY_CACHE_ROOT=str(item / "m1140-c-cost-cache"))
    sources = sorted((ROOT / "Sources/OrganicShell/Panels").glob(
            "*.swift")) + [ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"]
    fingerprint = lambda: {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    tools = [Path(__file__), ROOT / "tools/m1140/b-cost.py", ROOT / "tools/m1140/PanelsBCostMain.swift",
        ROOT / "tools/m1140/PanelsCRecordedData.swift"]
    receipt = {"job": job, "sourceHashes": fingerprint(),
        "toolHashes": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in tools},
               "bodyResourcesSHA256": hashlib.sha256((
                       ROOT / "Sources/OrganicShell/BodyPresentation/BodyResources.swift").read_bytes()).hexdigest(),
               "buildExit": None, "runExits": [], "checks": 0, "failures": [], "actualViolations": [],
                   "stopCondition": False,
               "clockDefinition":
                   "PanelsBCostMain.swift unchanged; replace host constructor and compare real bridge serial only"}
    records = []
    try:
        command = [sys.executable, "tools/m11/check_package.py", "--root", str(ROOT), "--package", str(package),
                   "--body-assets", str(item / "m1140-check-bodies"), "--name", "M1140LiveCosts", "--define",
                       "CORE_SELFTEST", "--define", "CHECK_PACKAGE_WHOLE_TREE", "--exclude", "CoreVerification.swift",
                   "--add", "tools/m1140/PanelsBCostMain.swift", "--add", "tools/m1140/PanelsCRecordedData.swift"]
        code = baseline.helper.run(command, out / "prepare.log", deadline, env)
        if code: return code
        path = package / "Sources/Check/PanelsBCostMain.swift"
        original = path.read_text(encoding="utf-8")
        assert original.count("FunctionPanelTextureMockHost(") == 3
        assert original.count("warm.owner.currentPicture?.event?.serial == 3") == 1
        adapted = original.replace("FunctionPanelTextureMockHost(", "FunctionPanelCCostHost(").replace(
            "warm.owner.currentPicture?.event?.serial == 3",
                "warm.owner.currentPicture?.event?.serial == warm.phaseInput?.event.serial")
        if path.is_symlink(): path.unlink()
        path.write_bytes(adapted.encode("utf-8"))
        receipt["adaptedMainSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        receipt["buildExit"] = baseline.helper.run(["swift", "build", "--package-path", str(package), "-c", "debug",
                "-j", "4"], out / "build.log", deadline, env)
        if receipt["buildExit"]: return receipt["buildExit"]
        for scale in [1, 2]:
            for index in range(5):
                path = out / ("s%d-%d.json" % (scale, index))
                code = baseline.helper.run([str(package / ".build/debug/Check"), str(scale), str(path)],
                    out / (path.stem + ".log"), deadline, env)
                receipt["runExits"].append(code)
                record = json.loads(path.read_text(encoding="utf-8")); records.append(record)
                receipt["checks"] += record["checks"]; receipt["failures"].extend(record["failures"])
                violations = baseline.actual_violations(record)
                if violations:
                    receipt["actualViolations"].append({"file": path.name, "violations": violations})
                    receipt["stopCondition"] = True
                    return 1
                if code or record["failures"]: return code or 1
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
            summary[key] = {"n": len(raw), "p50_ms": ordered[(len(ordered) - 1) // 2],
                            "p90_ms": ordered[min(len(ordered) - 1, int(len(ordered) * 0.9))], "max_ms": max(raw),
                                "raw_ms": raw}
        (out / "summary.json").write_bytes((json.dumps({"latencyGate": {"scale": 2, "eachSample": True,
                "limitsMS": baseline.LIMITS, "HDBytes": 16777216},
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
