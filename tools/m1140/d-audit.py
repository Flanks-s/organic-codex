"""Local readback audit: scope, immutable report prefix, UTF-8/LF and product fingerprints."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    baseline = json.loads((ROOT / "tools/m1140/evidence/d-preflight.json").read_text(encoding="utf-8"))
    report = ROOT / "docs/reference/M11-40-PANELS-PLAN-SOL-261112.md"
    data = report.read_bytes()
    assert hashlib.sha256(data[:baseline["reportBytes"]]).hexdigest() == baseline["reportSHA"]
    changes = subprocess.check_output(["git", "diff", "--name-only"], cwd=ROOT, text=True).splitlines()
    untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT,
        text=True).splitlines()
    allowed = lambda p: p.startswith(("Sources/OrganicShell/Panels/",
            "tools/m1140/")) or p == report.relative_to(ROOT).as_posix()
    assert all(allowed(p) for p in changes + untracked), changes + untracked
    for p, expected in baseline["shared"].items():
        assert hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == expected, p
    files = sorted((ROOT / "Sources/OrganicShell/Panels").glob(
            "*.swift")) + [ROOT / "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"]
    hashes = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    for p in [ROOT / name for name in changes + untracked if (ROOT / name).is_file()]:
        raw = p.read_bytes(); raw.decode("utf-8", errors="strict")
        assert b"\r" not in raw and not raw.startswith(b"\xef\xbb\xbf"), p
    assert "??" not in data[baseline["reportBytes"]:].decode("utf-8")
    names = ["FunctionPanelActionOwner", "FunctionPanelActionHost", "FunctionPanelView", "FunctionPanelLiveHost",
        "FunctionPanelProjection"]
    callers = [p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources").rglob("*.swift")
               if "Panels" not in p.parts and any(name in p.read_text(encoding="utf-8") for name in names)]
    assert not callers, callers
    result = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "reportPrefixBytes": baseline["reportBytes"], "reportPrefixSHA256": baseline["reportSHA"],
              "sourceHashes": hashes, "shared": baseline["shared"], "changed": changes, "new": untracked,
              "normalProductCallers": callers, "UTF8NoBOMLF": True}
    (ROOT / "tools/m1140/evidence/d-final-audit.json").write_bytes((json.dumps(result, indent=2,
            ensure_ascii=False) + "\n").encode("utf-8"))
    print(json.dumps({"products": len(hashes), "changes": len(changes), "new": len(untracked),
            "normalProductCallers": callers, "UTF8NoBOMLF": True}))


if __name__ == "__main__":
    main()
