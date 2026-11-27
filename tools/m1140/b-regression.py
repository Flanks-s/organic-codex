"""Run unchanged regression checks against a manifest-verified B0 or candidate."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
def baseline(_):
    raise SystemExit("The old baseline is unavailable; use tools/m1140/rebased-pair.py.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["compact", "phase", "phase-host", "pressure", "release", "wiring", "a",
            "phase-task"])
    parser.add_argument("version", choices=["baseline", "candidate"])
    args = parser.parse_args()
    started = time.monotonic(); deadline = started + min(1150, float(os.environ.get("M1140_B_BUDGET", "1150")))
    item = Path(os.environ["OC_ITEM_DIR"])
    out = Path(os.environ["OUT"]) / "m1140-b-regression" / (
        args.suite + "-" + args.version + "-" + os.environ["OC_JOB"])
    out.mkdir(parents=True, exist_ok=True)
    root, proof = baseline(item) if args.version == "baseline" else (ROOT, {})
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1",
        ORGANIC_BODY_CACHE_ROOT=str(item / ("m1140-reg-cache-" + args.version)))
    record = {"suite": args.suite, "version": args.version, "baselineProof": proof, "commands": []}

    def run(command, name):
        with (out / (name + ".log")).open("w") as stream:
            child = subprocess.Popen(command, cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT,
                start_new_session=True)
            print("child_pid=" + str(child.pid), flush=True)
            try:
                code = child.wait(timeout=max(1, deadline-time.monotonic()))
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL); child.wait()
                raise TimeoutError("Regression task exceeded 1150 seconds")
        print("\n".join((out / (name + ".log")).read_text(errors="replace").splitlines()[-22:]), flush=True)
        record["commands"].append({"command": [str(x) for x in command], "exit": code})
        if code:
            raise RuntimeError(name + " failed with exit " + str(code))

    try:
        if args.suite == "a":
            env["M1140_TASK_BUDGET_SECONDS"] = str(max(1, deadline - time.monotonic() - 3))
            run([sys.executable, str(ROOT / "tools/m1140/check.py"), "restored"], "a-restored")
        elif args.suite == "phase":
            run(["zsh", "tools/bodies/phase-check.zsh", str(out / "phase")], "phase")
            report = json.loads((out / "phase/results/phase-contract.json").read_text())
            saved = item / ("m1140-phase-" + args.version + ".json")
            saved.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
            other = item / ("m1140-phase-" + ("candidate" if args.version == "baseline" else "baseline") + ".json")
            if other.exists():
                comparison = {"equal": report == json.loads(other.read_text()), "checks": report["checks"]}
                (out / "phase-module-comparison.json").write_text(json.dumps(comparison, indent=2) + "\n")
                assert comparison["equal"], "Phase module output differs from B0"
        elif args.suite == "phase-task":
            run([sys.executable, "tools/m1145/phase-host-mutations.py", str(out / "existing-task"),
                 "--only", "task", "--cache", str(item / "m1140-existing-phase-task")], "phase-task")
            mutants = json.loads((out / "existing-task/mutations.json").read_text())
            assert len(mutants) == 1 and mutants[0]["exit"] == 1 and mutants[0]["caught"], mutants
        elif args.suite == "phase-host":
            env["M1145_CHECK_PACKAGE"] = str(item / ("m1140-phase-host-" + args.version))
            run(["zsh", "tools/m1145/phase-host-check.zsh", str(out / "phase-host")], "phase-host")
        elif args.suite in {"compact", "pressure"}:
            package = item / ("m1140-compact-package" if args.suite == "compact" else "m1140-pressure-package")
            adds = [ROOT / "tools/m1140/CompactPhaseProbe.swift"] if args.suite == "compact" else [root /
                "tools/m1145/R5PressureProbe.swift", root / "tools/m1145/R5Trace.swift"]
            command = [sys.executable, str(root / "tools/m11/check_package.py"), "--root", str(root),
                       "--package", str(package), "--name", "M1140Regression", "--body-assets",
                           str(item / "m1140-check-bodies")]
            for path in adds: command += ["--add", str(path)]
            for path in (root / "Sources/OrganicShell/Panels").glob("*.swift"): command += ["--exclude", path.name]
            if args.suite == "pressure":
                command = [sys.executable, "tools/m1145/r5-trace-prepare.py", str(out / "instrumented"), str(package)]
            run(command, "prepare")
            run(["swift", "build", "--package-path", str(package), "-c", "debug", "-j", "4"], "build")
            run([str(package / ".build/debug/Check"), str(out / "results")], "run")
            if args.suite == "compact":
                report = json.loads((out / "results/report.json").read_text())
                saved = item / ("m1140-compact-" + args.version + ".json")
                saved.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
                other = item / ("m1140-compact-" + (
                        "candidate" if args.version == "baseline" else "baseline") + ".json")
                if other.exists():
                    comparison = {"equal": report == json.loads(other.read_text()), "rows": len(report["rows"]),
                        "hosts": len(report["hostRows"]), "rates": len(report["samplingRates"])}
                    (out / "default-path-comparison.json").write_text(json.dumps(comparison, indent=2) + "\n")
                    assert comparison["equal"], "STOP: default compact pixels / ledger / counters differ from B0"
        elif args.suite == "release":
            run(["zsh", "scripts/build.sh"], "release")
        elif args.suite == "wiring":
            env["OUT"] = str(out)
            run(["zsh", "tools/m1139/p160-wiring.zsh"], "wiring")
        return 0
    finally:
        record["seconds"] = time.monotonic() - started
        (out / "receipt.json").write_text(json.dumps(record, indent=2) + "\n")
        print(json.dumps(record), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
