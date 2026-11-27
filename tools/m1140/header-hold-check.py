"""Reuse P3's bounded private-package runner for the windowless Header hold contract."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("hold_runner", ROOT / "tools/m1140/p3-check.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.MUTATIONS = {
    "boolean": ("HeaderIslandHold.swift", "entries.remove(at: index)",
        "entries.removeAll { $0.token.role == token.role }", "hold.count"),
    "restore-others": ("HeaderIslandHold.swift", "apply(token.role, writes: entry.writes)",
        "for (role, fields) in originals {\n"
        "            for (write, pose) in fields { host?.headerHoldApply(pose, role: role, write: write) }\n"
        "        }\n        apply(token.role, writes: entry.writes)", "hold.release"),
    "dispose-held": ("HeaderIslandHold.swift", "entries.removeAll() // Hold.invalidate",
        "if reason != .disposed { entries.removeAll() } // Hold.invalidate", "hold.dispose"),
    "stale-release": ("HeaderIslandHold.swift",
        "guard let index = entries.firstIndex(where: { $0.token == token }) else { return false }",
        "guard let index = entries.firstIndex(where: {\n"
        "            $0.token.role == token.role && $0.token.holder == token.holder\n"
        "        }) else { return false }", "hold.stale"),
}
original_run = runner.helper.run
def run(command, *arguments):
    if "--add" in command:
        command[command.index("tools/m1140/PanelsWindowCheckMain.swift")] = "tools/m1140/HeaderHoldCheckMain.swift"
        index = command.index("tools/m1140/PanelsCRecordedData.swift") - 1
        del command[index:index + 2]
    return original_run(command, *arguments)
runner.helper.run = run
if __name__ == "__main__":
    source = "Sources/OrganicShell/Island/HeaderIslandHold.swift"
    before = hashlib.sha256((ROOT / source).read_bytes()).hexdigest()
    code = runner.main()
    path = Path(os.environ["OUT"]) / "m1140-p3" / (sys.argv[1] + "-" + os.environ["OC_JOB"]) / "receipt.json"
    receipt = json.loads(path.read_text(encoding="utf-8"))
    receipt["sourceHashes"][source] = before
    receipt["sourceUnchanged"] &= before == hashlib.sha256((ROOT / source).read_bytes()).hexdigest()
    path.write_bytes((json.dumps(receipt, indent=2) + "\n").encode("utf-8"))
    raise SystemExit(code if receipt["sourceUnchanged"] else 3)
