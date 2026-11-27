"""Bounded B suite; all mutations are private package copies."""
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
    "context-placement": (
        "FunctionPanelView.swift", "guard bounds.width > 80 else { return }",
        "guard bounds.width > .infinity else { return }", "context.placement",
    ),
    "track-text-unbounded": ("FunctionPanelPrimitives.swift", "static let truncatesOverflow = true",
        "static let truncatesOverflow = false", "subagents.text-lines"),
    "overlay-passthrough": ("FunctionPanelOverlayMockHost.swift", "return stage?.hitTest(point) ?? self",
        "return stage?.hitTest(point)", "overlay.no-passthrough"),
    "release-hd": ("FunctionPanelBodyOwner.swift", "closed = true; generation += 1; cancelImages(); hd.dispose()",
                   "closed = true; generation += 1; cancelImages()", "resources.release-HD"),
    "upscaled": ("BodyPhaseStream.swift", "samplingOuter:Float(targetOuter))", "samplingOuter:Float(56))",
        "hd.native-raster"),
    "context-phase": ("FunctionPanelTextureMockHost.swift", "value: .init(state, fraction: 0.37)",
                      "value: .init(state, fraction: 0.61)", "phase.not-context"),
    "tick": ("BodyPhaseStream.swift",
        "if (finished && self.lastSample == sample || self.settledEvent == self.playback.event),",
             "if false,(finished && self.lastSample == sample || self.settledEvent == self.playback.event),",
                 "resources.no-resident-tick"),
    "uncancelled": ("FunctionPanelBodyOwner.swift",
        "private func cancelImages() {\n        for task in jobs.values { task.cancel() }\n    }",
                    "private func cancelImages() {}", "resources.cancel-image-tasks"),
    "overlap": ("FunctionPanelBodySnapshot.swift", "[[0, 235, 243, 251, 259]", "[[0, 235, 235, 235, 235]",
        "tracks.no-overlap"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=["build", "positive", "restored", "overlay-positive",
            "overlay-restored"] + list(MUTATIONS))
    args = parser.parse_args()
    started = time.monotonic()
    deadline = started + min(1150, float(os.environ.get("M1140_B_BUDGET", "1150")))
    item = Path(os.environ["OC_ITEM_DIR"])
    job = os.environ["OC_JOB"]
    out = Path(os.environ["OUT"]) / "m1140-b" / (args.case + "-" + job)
    out.mkdir(parents=True, exist_ok=True)
    package = item / "m1140-b-package"
    sources = sorted((ROOT / "Sources/OrganicShell/Panels").glob(
            "*.swift")) + [ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"]
    fingerprint = lambda: {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    receipt = {"case": args.case, "job": job, "sourceHashes": fingerprint(), "buildExit": None, "runExit": None}
    main_file = "tools/m1140/PanelsOverlayCheckMain.swift" if args.case.startswith(
        "overlay-") else "tools/m1140/PanelsBCheckMain.swift"
    receipt["checkMain"] = main_file
    receipt["checkMainSHA256"] = hashlib.sha256((ROOT / main_file).read_bytes()).hexdigest()
    receipt["runnerSHA256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", ORGANIC_BODY_CACHE_ROOT=str(item / "body-cache"))

    def run(command, name):
        with (out / (name + ".log")).open("w", encoding="utf-8", newline="\n") as stream:
            child = subprocess.Popen(command, cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                start_new_session=True)
            print("child_pid=" + str(child.pid), flush=True)
            try:
                code = child.wait(timeout=max(1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                raise TimeoutError("B task deadline exceeded")
        print("\n".join((out / (name + ".log")).read_text(encoding="utf-8", errors="replace").splitlines()[-12:]),
            flush=True)
        return code

    try:
        prepare = [sys.executable, "tools/m11/check_package.py", "--root", str(ROOT), "--package", str(package),
                   "--body-assets", str(item / "m1140-check-bodies"), "--name", "M1140PanelsB",
                   "--add", main_file, "--define", "CHECK_PACKAGE_WHOLE_TREE"]
        code = run(prepare, "prepare")
        if code:
            return code
        if args.case in MUTATIONS:
            name, old, new, category = MUTATIONS[args.case]
            file = package / "Sources/Check" / name
            text = file.read_text(encoding="utf-8")
            assert text.count(old) == 1, (args.case, text.count(old))
            if file.is_symlink():
                file.unlink()
            file.write_bytes(text.replace(old, new).encode("utf-8"))
            receipt["expectedCategory"] = category
        receipt["buildExit"] = run(["swift", "build", "--package-path", str(package), "-c", "debug", "-j", "4"],
            "build")
        if receipt["buildExit"] or args.case == "build":
            return receipt["buildExit"]
        command = [str(package / ".build/debug/Check"), str(out)]
        if args.case in MUTATIONS:
            command.append("--no-frames")
        receipt["runExit"] = run(command, "run")
        report = json.loads((out / "report.json").read_text(encoding="utf-8"))
        receipt.update(checks=report["checks"], failures=report["failures"], frames=len(report["frames"]))
        if args.case in MUTATIONS:
            receipt["validNegative"] = receipt["runExit"] == 1 and report["checks"] > 0 and any(f.startswith(
                    receipt["expectedCategory"]) for f in report["failures"])
            if args.case in ("track-text-unbounded", "context-placement"):
                receipt["onlyExpectedCategory"] = all(f.startswith(
                        receipt["expectedCategory"]) for f in report["failures"])
                receipt["validNegative"] = receipt["validNegative"] and receipt["onlyExpectedCategory"]
            return 0 if receipt["validNegative"] else 2
        return receipt["runExit"] if report["checks"] else 3
    finally:
        receipt["sourceUnchanged"] = receipt["sourceHashes"] == fingerprint()
        receipt["seconds"] = time.monotonic() - started
        (out / "receipt.json").write_bytes((json.dumps(receipt, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
        print(json.dumps(receipt, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
