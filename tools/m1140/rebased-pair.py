"""Freeze a mainline build tree plus M11.40; reuse the original regression runner."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
STREAM = "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"
PANELS = "Sources/OrganicShell/Panels/"
TOOLS = "tools/m1140/"
INPUTS = [".gitignore", "Package.swift", "Package.resolved", "Sources", "Resources",
          "Runtime", "scripts", "tools", "design"]


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def sha(data):
    return hashlib.sha256(data).hexdigest()


def hashes(tree):
    result = {}
    for path in sorted(tree.rglob("*")):
        if path.is_file():
            result[path.relative_to(tree).as_posix()] = sha(path.read_bytes())
    return result


def verify(pair, record):
    for side, expected in record["trees"].items():
        tree = pair / side
        for name, digest in expected.items():
            assert sha((tree / name).read_bytes()) == digest, (side, name)
            if os.name != "nt" and name in record["modes"]:
                assert (tree / name).stat().st_mode & 0o777 == record["modes"][name], (side, name)
        sources = {p.relative_to(tree).as_posix() for p in (tree / "Sources").rglob("*.swift")}
        assert sources == {n for n in expected if n.startswith("Sources/") and n.endswith(".swift")}
    before = record["trees"]["baseline"]
    after = record["trees"]["candidate"]
    shared = {n for n in before if n.startswith("Sources/")}
    shared.update(n for n in after if n.startswith("Sources/") and not n.startswith(PANELS))
    assert [n for n in sorted(shared) if before.get(n) != after.get(n)] == [STREAM]


def overlay(base):
    ancestor = git("merge-base", "HEAD", base).decode().strip()
    assert git("show", base + ":" + STREAM) == git("show", ancestor + ":" + STREAM), "Review upstream Stream first"
    names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", PANELS, TOOLS)
    files = {name.decode() for name in names.split(b"\0") if name}
    files.add(STREAM)
    result = {}
    for name in sorted(files):
        path = ROOT / name
        assert path.is_file() and not path.is_symlink(), name
        path.resolve().relative_to(ROOT.resolve())
        result[name] = path.read_bytes()
    return result


def prepare(ref, destination):
    base = git("rev-parse", "--verify", ref + "^{commit}").decode().strip()
    files = overlay(base)
    digests = {name: sha(data) for name, data in files.items()}
    digest = sha(json.dumps(digests, sort_keys=True).encode())
    key = base[:12] + "-" + digest[:16]
    destination.resolve().relative_to((ROOT / TOOLS).resolve())
    pair = destination.resolve() / key
    if pair.exists():
        record = json.loads((pair / "pair.json").read_text(encoding="utf-8"))
        assert record["base"] == base and record["overlay"] == digests
        verify(pair, record)
    else:
        pair.mkdir(parents=True)
        baseline = pair / "baseline"
        baseline.mkdir()
        modes = {}
        with tarfile.open(fileobj=io.BytesIO(git("archive", base, "--", *INPUTS))) as archive:
            for member in archive:
                if member.isdir():
                    continue
                assert member.isfile(), member.name
                path = baseline / member.name
                path.resolve().relative_to(baseline.resolve())
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(archive.extractfile(member).read())
                path.chmod(member.mode & 0o777)
                modes[member.name] = member.mode & 0o777
        assert not any((baseline / "Sources/OrganicShell/Panels").glob("*.swift"))
        candidate = pair / "candidate"
        shutil.copytree(baseline, candidate)
        for name, data in files.items():
            path = candidate / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        record = {
            "base": base, "head": git("rev-parse", "HEAD").decode().strip(), "key": key,
            "overlay": digests, "seed": 17, "modes": modes,
            "trees": {"baseline": hashes(baseline), "candidate": hashes(candidate)},
        }
        verify(pair, record)
        (pair / "pair.json").write_bytes((json.dumps(record, indent=2) + "\n").encode("utf-8"))
    bundle = pair.with_suffix(".tar.gz")
    if not bundle.exists():
        def restore_mode(member):
            if member.isdir():
                member.mode |= 0o111
                return member
            parts = member.name.split("/", 2)
            if len(parts) == 3 and parts[1] in ("baseline", "candidate"):
                member.mode = record["modes"].get(parts[2], 0o644)
            return member
        with tarfile.open(bundle, "w:gz") as archive:
            archive.add(pair, arcname=pair.name, filter=restore_mode)
    with tarfile.open(bundle) as archive:
        for member in archive:
            if member.isdir():
                assert member.mode & 0o111 == 0o111, member.name
            elif member.isfile():
                parts = member.name.split("/", 2)
                if len(parts) == 3 and parts[1] in ("baseline", "candidate"):
                    assert member.mode == record["modes"].get(parts[2], 0o644), member.name
    print(json.dumps({"pair": str(pair), "bundle": str(bundle), "bundleSHA256": sha(bundle.read_bytes())}))
    return pair


def run(pair, suite, side, case):
    record = json.loads((pair / "pair.json").read_text(encoding="utf-8"))
    verify(pair, record)
    item = Path(os.environ["OC_ITEM_DIR"]) / ("m1140-pair-" + record["key"])
    item.mkdir(parents=True, exist_ok=True)
    os.environ["OC_ITEM_DIR"] = str(item)
    source = pair / "candidate"
    spec = importlib.util.spec_from_file_location("rebased_regression", source / TOOLS / "b-regression.py")
    module = importlib.util.module_from_spec(spec)
    sys.dont_write_bytecode = True
    spec.loader.exec_module(module)
    module.ROOT = source
    module.baseline = lambda _: (pair / "baseline", {"base": record["base"], "key": record["key"]})
    sys.argv = [str(source / TOOLS / "b-regression.py"), suite, side]
    code = None
    direct = {
        "a": ["check.py", case],
        "p3": ["p3-check.py", case],
        "b": ["b-check.py", case], "c": ["c-check.py", case], "d": ["d-check.py", case],
        "overlay": ["b-check.py", "overlay-" + case],
        "mock-cost": ["b-cost.py", "--case", case],
        "live-cost": ["c-cost.py"], "action-cost": ["d-cost.py"],
    }
    try:
        cases = ("a", "b", "c", "d", "p3", "overlay", "mock-cost")
        assert case == "positive" or suite in cases, "Unsupported case"
        if suite in direct:
            assert side == "candidate", "These suites require the candidate Panels"
            script, *arguments = direct[suite]
            code = subprocess.call([sys.executable, str(source / TOOLS / script), *arguments], cwd=source)
        else:
            code = module.main()
        return code
    finally:
        verify(pair, record)
        out = Path(os.environ["OUT"]) / "m1140-rebased"
        out.mkdir(parents=True, exist_ok=True)
        resources = "Sources/OrganicShell/BodyPresentation/BodyResources.swift"
        receipt = {
            "base": record["base"], "pair": record["key"], "suite": suite, "side": side, "case": case, "exit": code,
            "sourceHashes": {n: h for n, h in record["overlay"].items() if n.startswith("Sources/")},
            "bodyResourcesSHA256": record["trees"]["candidate"][resources],
        }
        name = os.environ["OC_JOB"] + "-" + suite + "-" + side + ".json"
        (out / name).write_bytes((json.dumps(receipt, indent=2) + "\n").encode("utf-8"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    freeze = modes.add_parser("prepare")
    freeze.add_argument("--base", default="organic-animation")
    freeze.add_argument("--output", type=Path, default=ROOT / TOOLS / ".build/pairs")
    execute = modes.add_parser("run")
    execute.add_argument("pair", type=Path)
    execute.add_argument("suite", choices=["compact", "phase", "phase-host", "pressure", "release", "wiring", "a",
                                         "phase-task", "b", "c", "d", "p3", "overlay",
                                         "mock-cost", "live-cost", "action-cost"])
    execute.add_argument("side", choices=["baseline", "candidate"])
    execute.add_argument("--case", default="positive")
    args = parser.parse_args()
    if args.mode == "prepare":
        prepare(args.base, args.output)
        return 0
    return run(args.pair.resolve(), args.suite, args.side, args.case)


if __name__ == "__main__":
    raise SystemExit(main())
