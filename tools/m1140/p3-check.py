"""Bounded, windowless popup-host checks; mutations affect private package copies only."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("panel_helper", ROOT / "tools/m1140/check.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
MUTATIONS = {
    "model-wrong-next": ("OverlayComposerBinding.swift", "            composer.setSettings(settings)",
        "            target.settings = settings", "model.next"),
    "artifact-thread": ("CoreArtifactsController.swift", ".filter(scope.admits)", "", "artifact.thread"),
    "artifact-selection": ("CoreArtifactsController.swift", "let owned = values",
        "selectedID = \"mutated\"\n            let owned = values", "artifact.selection"),
    "artifact-late": ("FunctionPanelArtifactPreview.swift", "accepts(ticket) && visible.contains(id)",
        "visible.contains(id)", "artifact.late"),
    "artifact-bytes": ("FunctionPanelProjection.swift", 'artifact.raw["bytes"]?.intValue, bytes >= 0',
        'Optional(artifact.bytes), bytes >= 0', "artifact.bytes"),
    "private-ledger": ("FunctionPanelWindowOwner.swift",
        "body = FunctionPanelBodyOwner(resources: resources) // P3.resources",
        "body = FunctionPanelBodyOwner(resources: BodyResources()) // P3.resources", "window.resources"),
    "close-work": ("FunctionPanelWindowOwner.swift", "body?.close() // P3.close",
        "// P3.close omitted", "window.close"),
    "stale-image": ("FunctionPanelWindowOwner.swift",
        "guard let self, self.isOpen, self.generation == ticket else { return } // P3.generation",
        "guard let self else { return } // P3.generation", "window.stale"),
    "resident-tick": ("FunctionPanelView.swift",
        "if !needsFrames { timer?.invalidate(); timer = nil }",
        "if false {\n"
        "            timer?.invalidate()\n"
        "            timer = nil\n"
        "        }", "window.tick"),
    "neighbour-active": ("FunctionPanelWindowOwner.swift", "restoreColumns = columns.suspend() // P3.pause",
        "restoreColumns = nil // P3.pause omitted", "window.pause"),
    "no-restore": ("FunctionPanelWindowOwner.swift", "restoreColumns?() // P3.restore",
        "// P3.restore omitted", "window.restore"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=["positive", "restored"] + list(MUTATIONS))
    args = parser.parse_args()
    item = Path(os.environ["OC_ITEM_DIR"])
    out = Path(os.environ["OUT"]) / "m1140-p3" / (args.case + "-" + os.environ["OC_JOB"])
    out.mkdir(parents=True, exist_ok=True)
    package = item / "m1140-p3-package"
    sources = sorted((ROOT / "Sources/OrganicShell/Panels").glob("*.swift"))
    sources.append(ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift")
    hashes = {}
    for path in sources:
        hashes[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    receipt = {"case": args.case, "sourceHashes": hashes, "buildExit": None, "runExit": None}
    started = time.monotonic()
    deadline = started + 1150
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1", ORGANIC_BODY_CACHE_ROOT=str(item / "m1140-p3-cache"))
    try:
        command = [sys.executable, str(ROOT / "tools/m11/check_package.py"), "--root", str(ROOT),
            "--package", str(package), "--name", "M1140PanelsWindow", "--define", "CHECK_PACKAGE_WHOLE_TREE",
            "--define", "CORE_SELFTEST", "--exclude", "CoreVerification.swift",
            "--body-assets", str(item / "m1140-check-bodies"),
            "--add", "tools/m1140/PanelsWindowCheckMain.swift", "--add", "tools/m1140/PanelsCRecordedData.swift"]
        receipt["prepareExit"] = helper.run(command, out / "prepare.log", deadline, env)
        if receipt["prepareExit"]:
            return receipt["prepareExit"]
        if args.case in MUTATIONS:
            name, old, new, category = MUTATIONS[args.case]
            path = package / "Sources/Check" / name
            text = path.read_text(encoding="utf-8")
            assert text.count(old) == 1, (name, text.count(old))
            if path.is_symlink():
                path.unlink()
            path.write_bytes(text.replace(old, new).encode("utf-8"))
            receipt["expectedCategory"] = category
        build = ["swift", "build", "--package-path", str(package), "-c", "debug", "-j", "4"]
        receipt["buildExit"] = helper.run(build, out / "build.log", deadline, env)
        if receipt["buildExit"]:
            return receipt["buildExit"]
        command = [str(package / ".build/debug/Check"), str(out)]
        if args.case.startswith("artifact-") or os.environ.get("M1140_ARTIFACTS"): command.append("--artifacts")
        if args.case == "model-wrong-next" or os.environ.get("M1140_MODEL"): command.append("--model")
        if args.case in MUTATIONS:
            command.append("--no-frames")
        receipt["runExit"] = helper.run(command, out / "run.log", deadline, env)
        report_path = out / "report.json"
        if receipt["runExit"] not in (0, 1) or not report_path.is_file():
            receipt["error"] = "executable crashed or report.json missing; runExit=" + str(receipt["runExit"])
            return 3
        report = json.loads(report_path.read_text(encoding="utf-8"))
        receipt.update(checks=report["checks"], failures=report["failures"])
        if args.case in MUTATIONS:
            category = receipt["expectedCategory"]
            only = bool(report["failures"]) and set(report["failures"]) == {category}
            receipt["validNegative"] = receipt["runExit"] == 1 and only
            return 0 if receipt["validNegative"] else 2
        return receipt["runExit"] if report["checks"] else 3
    finally:
        unchanged = True
        for name, expected in hashes.items():
            unchanged = unchanged and hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == expected
        receipt["sourceUnchanged"] = unchanged
        receipt["seconds"] = time.monotonic() - started
        (out / "receipt.json").write_bytes((json.dumps(receipt, indent=2) + "\n").encode("utf-8"))
        print(json.dumps(receipt), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
