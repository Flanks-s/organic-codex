"""Local scope / UTF-8 audit for the operation-error correction, without touching git."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
E = ROOT / "tools/m1140/evidence"


def main():
    baseline = json.loads((E / "r5e-preflight.json").read_text(encoding="utf-8"))
    report = ROOT / "docs/reference/M11-40-PANELS-PLAN-SOL-261112.md"
    data = report.read_bytes()
    assert hashlib.sha256(data[:baseline["reportBytes"]]).hexdigest() == baseline["reportSHA"]
    changed = subprocess.check_output(["git", "diff", "--name-only"], cwd=ROOT, text=True).splitlines()
    new = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT,
        text=True).splitlines()
    assert all(p.startswith(("Sources/OrganicShell/Panels/",
            "tools/m1140/")) or p == report.relative_to(ROOT).as_posix() for p in changed + new)
    for p, expected in baseline["shared"].items():
        assert hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == expected, p
    for p in [ROOT / name for name in changed + new if (ROOT / name).is_file()]:
        raw = p.read_bytes(); raw.decode("utf-8", errors="strict")
        assert b"\r" not in raw and not raw.startswith(b"\xef\xbb\xbf"), p
    assert "??" not in data[baseline["reportBytes"]:].decode("utf-8")
    files = sorted((ROOT / "Sources/OrganicShell/Panels").glob(
            "*.swift")) + [ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"]
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    names = ["FunctionPanelActionOwner", "FunctionPanelActionHost", "FunctionPanelView", "FunctionPanelLiveHost",
        "FunctionPanelProjection"]
    callers = [p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources").rglob("*.swift")
               if "Panels" not in p.parts and any(name in p.read_text(encoding="utf-8") for name in names)]
    assert not callers, callers
    assertions = {}
    for name in ["PanelsCCheckMain.swift", "PanelsDCheckMain.swift"]:
        old = subprocess.check_output(["git", "show", "HEAD:tools/m1140/" + name], cwd=ROOT).decode("utf-8")
        original = [line for line in old.splitlines() if "check(" in line]
        current = (ROOT / "tools/m1140" / name).read_text(encoding="utf-8").splitlines()
        assert all(line in current for line in original), name
        assertions[name] = len(original)
    unchanged = {}
    for name in ["check.py", "b-check.py", "b-cost.py", "c-check.py", "c-cost.py", "d-cost.py",
        "PanelsBCostMain.swift"]:
        raw = (ROOT / "tools/m1140" / name).read_bytes()
        assert raw == subprocess.check_output(["git", "show", "HEAD:tools/m1140/" + name], cwd=ROOT), name
        unchanged[name] = hashlib.sha256(raw).hexdigest()
    result = dict(baseline=baseline, sourceHashes=hashes, changed=changed, new=new, normalProductCallers=callers,
                  originalAssertionSourceLines=assertions, unchangedCheckers=unchanged, UTF8NoBOMLF=True)
    (E / "r5e-audit.json").write_bytes((json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    print(json.dumps(dict(products=len(hashes), changed=len(changed), new=len(new), sharedChanged=0,
            normalProductCallers=callers, UTF8NoBOMLF=True)))


if __name__ == "__main__":
    main()
