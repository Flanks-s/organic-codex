"""D action checks against an isolated real Store/Runtime with in-memory transport only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("panel_helper", ROOT / "tools/m1140/check.py")
helper = module_from_spec(spec); spec.loader.exec_module(helper)
MUTATIONS = {
    "no-target": ("guard parentMatches && childMatches else", "guard true else", "actions.guard.target"),
    "no-connection": ("guard connected() else", "guard true else", "actions.guard.connection"),
    "no-capability": ("guard capabilities().contains(key) else", "guard true else", "actions.guard.capability"),
    "duplicate-submit": ("guard !pending && !admitted.contains(action) else", "guard true else", "actions.dedup"),
    "no-rollback": ("result = error // D.rollback", "target.stopping = true; result = error // D.rollback",
        "actions.rollback"),
    "operation-as-read": ("if !c.historyLoaded, !c.loading, let error = c.operationError",
        "if let error = c.operationError", "reads.operation-error"),
    "read-failure-swallowed": ("if let error = sources.historyError { return .failed(error) }",
        "if sources.historyError != nil { return .unloaded }", "reads.failure"),
    "edit-callback": ("return isAmbiguous(error) ? .outcomeUnknown(reason) : .failed(reason)",
                      "return .accepted", "edits.receipt."),
    "edit-compact": ('"Compact request accepted"', '"Compaction complete"', "edits.compact"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=["positive", "restored", "edit-positive", "edit-restored"] + list(MUTATIONS))
    args = parser.parse_args()
    item = Path(os.environ["OC_ITEM_DIR"]); job = os.environ["OC_JOB"]
    out = Path(os.environ["OUT"]) / "m1140-d" / (args.case + "-" + job); out.mkdir(parents=True, exist_ok=True)
    package = item / "m1140-d-package"
    started = time.monotonic(); deadline = started + min(1150, float(os.environ.get("M1140_D_BUDGET", "1150")))
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", ORGANIC_BODY_CACHE_ROOT=str(item / "m1140-d-cache"))
    sources = sorted((ROOT / "Sources/OrganicShell/Panels").glob(
            "*.swift")) + [ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"]
    fingerprint = lambda: {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    tools = [Path(__file__), ROOT / "tools/m1140/PanelsDCheckMain.swift", ROOT / "tools/m1140/PanelsDReadErrors.swift",
        ROOT / "tools/m1140/PanelsDRecordedData.swift", ROOT / "tools/m1140/PanelsCRecordedData.swift"]
    receipt = {"case": args.case, "job": job, "sourceHashes": fingerprint(), "toolHashes": {p.name: hashlib.sha256(
            p.read_bytes()).hexdigest() for p in tools}, "buildExit": None, "runExit": None}
    try:
        command = [sys.executable, "tools/m11/check_package.py", "--root", str(ROOT), "--package", str(package),
                   "--body-assets", str(item / "m1140-check-bodies"), "--name", "M1140PanelsD", "--define",
                       "CHECK_PACKAGE_WHOLE_TREE", "--define", "CORE_SELFTEST",
                   "--exclude", "CoreVerification.swift", "--add", "tools/m1140/PanelsDCheckMain.swift", "--add",
                       "tools/m1140/PanelsDReadErrors.swift", "--add", "tools/m1140/PanelsDRecordedData.swift",
                       "--add", "tools/m1140/PanelsCRecordedData.swift"]
        code = helper.run(command, out / "prepare.log", deadline, env)
        if code: return code
        if args.case in MUTATIONS:
            path = package / "Sources/Check" / ("FunctionPanelProjection.swift" if args.case in ["operation-as-read",
                    "read-failure-swallowed"] else "FunctionPanelActionOwner.swift")
            if args.case == "edit-callback": path = path.with_name("LiveConversationRuntime.swift")
            old, new, category = MUTATIONS[args.case]
            text = path.read_text(encoding="utf-8")
            assert text.count(old) == 1, (args.case, text.count(old))
            if path.is_symlink(): path.unlink()
            path.write_bytes(text.replace(old, new).encode("utf-8"))
            receipt.update(expectedCategory=category, mutatedSHA256=hashlib.sha256(path.read_bytes()).hexdigest())
        receipt["buildExit"] = helper.run(["swift", "build", "--package-path", str(package), "-c", "debug", "-j", "4"],
            out / "build.log", deadline, env)
        if receipt["buildExit"]: return receipt["buildExit"]
        command = [str(package / ".build/debug/Check"), str(out)]
        if args.case.startswith("edit-"): command.append("--edit-results")
        if args.case in MUTATIONS: command.append("--no-frames")
        receipt["runExit"] = helper.run(command, out / "run.log", deadline, env)
        report = json.loads((out / "report.json").read_text(encoding="utf-8"))
        receipt.update(checks=report["checks"], failures=report["failures"], frames=len(report["frames"]))
        receipt["readErrorChecks"] = report["readErrorChecks"]
        if args.case in MUTATIONS:
            receipt["onlyExpectedCategory"] = bool(report["failures"]) and all(f.startswith(
                    receipt["expectedCategory"]) for f in report["failures"])
            receipt["validNegative"] = receipt["runExit"] == 1 and receipt["onlyExpectedCategory"]
            return 0 if receipt["validNegative"] else 2
        return receipt["runExit"] if report["checks"] else 3
    finally:
        receipt["sourceUnchanged"] = receipt["sourceHashes"] == fingerprint()
        receipt["seconds"] = time.monotonic() - started
        (out / "receipt.json").write_bytes((json.dumps(receipt, indent=2) + "\n").encode("utf-8"))
        print(json.dumps({k: v for k, v in receipt.items() if k != "sourceHashes"}), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
