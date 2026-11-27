"""One bounded MBA build/run. Mutations touch only private copies, never product links."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
MUTATIONS = {
    "six-pages": ("FunctionPanelInput.swift", "allCases }", "allCases + [.overview] }", "geometry.navigation-five"),
    "nine-bodies": ("FunctionPanelFixtures.swift", "].map { .init(id: $0.lowercased(), name: $0) }",
                    "].prefix(9).map { .init(id: $0.lowercased(), name: $0) }", "geometry.catalog-24"),
    "edge-unclipped": ("FunctionPanelGeometry.swift", "let diameter: CGFloat = fringe ? 9 : 22",
                       "let diameter: CGFloat = 22", "geometry.body-edge-clipping"),
    "index-selection": ("FunctionPanelView.swift", "self.input = input; state.reconcile(input); render()",
        "let oldIndex = state.pinnedSubagent.flatMap { id in self.input.subagents.value?.firstIndex { $0.id == id } }\n"
                        "        self.input = input; state.reconcile(input)\n"
                        "        if let oldIndex, let rows = input.subagents.value, rows.indices.contains(oldIndex) { "
                            "state.pinnedSubagent = rows[oldIndex].id }\n"
                        "        render()",
                        "identity.selection-survives-reorder"),
    "nil-zero": ("FunctionPanelInput.swift", "value.map(format) ?? status", "value.map(format) ?? \"0\"",
        "values.no-zero"),
    "resident-tick": ("FunctionPanelMotion.swift", "var needsFrames: Bool { active || swapping }",
                      "var needsFrames: Bool { true }", "motion.no-resident-tick"),
}


def run(command, log, deadline, env=None):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Task budget exhausted")
    with log.open("w", encoding="utf-8", newline="\n") as stream:
        proc = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                env=env, start_new_session=True)
        print("child_pid=" + str(proc.pid), flush=True)
        try:
            code = proc.wait(timeout=remaining)
        except subprocess.TimeoutExpired:
            # Only this task's recorded process group is signalled.
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            raise TimeoutError("Task exceeded 1,150 seconds")
    print("\n".join(log.read_text(encoding="utf-8", errors="replace").splitlines()[-45:]), flush=True)
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=["positive", "restored"] + list(MUTATIONS))
    parser.add_argument("--no-frames", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    budget = min(1150, max(30, float(os.environ.get("M1140_TASK_BUDGET_SECONDS", "1150"))))
    deadline = started + budget
    item = Path(os.environ["OC_ITEM_DIR"])
    job = os.environ.get("OC_JOB", "manual")
    output = Path(os.environ["OUT"]) / "m1140-a" / (args.case + "-" + job)
    output.mkdir(parents=True, exist_ok=True)
    package = item / "m1140-a-package"
    receipt = {"case": args.case, "job": job, "output": str(output), "buildExit": None,
               "runExit": None, "expectedCategory": None, "validNegative": False}
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", ORGANIC_BODY_CACHE_ROOT=str(item / "body-cache"))
    source_files = sorted((ROOT / "Sources/OrganicShell/Panels").glob("*.swift"))
    receipt["productSources"] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
    try:
        prepare = [sys.executable, str(ROOT / "tools/m11/check_package.py"), "--root", str(ROOT),
                   "--package", str(package), "--body-assets", str(item / "m1140-check-bodies"),
                   "--add", "tools/m1140/PanelsCheckMain.swift", "--define", "M1140_PANEL_SELFTEST",
                   "--define", "CHECK_PACKAGE_WHOLE_TREE", "--name", "M1140PanelsCheck"]
        code = run(prepare, output / "prepare.log", deadline, env)
        if code:
            return code
        if args.case in MUTATIONS:
            name, old, new, category = MUTATIONS[args.case]
            path = package / "Sources/Check" / name
            text = path.read_text(encoding="utf-8")
            if text.count(old) != 1:
                raise ValueError("Mutation anchor must match once: " + name)
            if path.is_symlink():
                path.unlink()
            path.write_bytes(text.replace(old, new).encode("utf-8"))
            receipt["expectedCategory"] = category
            receipt["mutatedSourceSHA256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        receipt["buildExit"] = run(["swift", "build", "--package-path", str(package), "-c", "debug", "-j", "4"],
            output / "build.log", deadline, env)
        if receipt["buildExit"]:
            return receipt["buildExit"]
        executable = package / ".build/debug/Check"
        command = [str(executable), str(output)]
        if args.case in MUTATIONS or args.no_frames:
            command.append("--no-frames")
        receipt["runExit"] = run(command, output / "run.log", deadline, env)
        report = json.loads((output / "report.json").read_text(encoding="utf-8"))
        receipt["checks"] = report["checks"]
        receipt["failures"] = report["failures"]
        receipt["frames"] = len(report["frames"])
        if args.case in MUTATIONS:
            target = receipt["expectedCategory"]
            receipt["validNegative"] = receipt["runExit"] == 1 and report["checks"] > 0 and any(name.startswith(
                    target) for name in report["failures"])
            return 0 if receipt["validNegative"] else 2
        return receipt["runExit"] if report["checks"] > 0 else 3
    finally:
        receipt["elapsedSeconds"] = time.monotonic() - started
        receipt["sourceUnchanged"] = receipt["productSources"] == {p.name: hashlib.sha256(p.read_bytes()).hexdigest(
                ) for p in source_files}
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(json.dumps(receipt, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
