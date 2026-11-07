#!/usr/bin/env python3
"""Standalone offscreen checks. Hidden filename keeps SwiftPM from treating this helper as an app resource."""
from pathlib import Path
import argparse
import io
import subprocess
import tarfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["all", "native", "normie", "debug", "overlay", "settings", "header_ax"], default="all", nargs="?")
    parser.add_argument("--baseline", default="83b2071")
    parser.add_argument("--output", type=Path, default=Path("/tmp/organic-native-ax-look"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    archived = args.output / "committed-dependencies"
    archived.mkdir(exist_ok=True)
    archive = subprocess.check_output(["git", "archive", args.baseline,
        "Sources/OrganicShell/Core", "Sources/OrganicShell/Orb", "Sources/OrganicShell/Tools"], cwd=repo)
    with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
        for member in contents.getmembers():
            destination = (archived / member.name).resolve()
            if not destination.is_relative_to(archived.resolve()) or member.issym() or member.islnk():
                raise ValueError("Unsafe dependency archive member: " + member.name)
        contents.extractall(archived)
    source = repo / "Sources/OrganicShell"
    baseline = archived / "Sources/OrganicShell"
    groups = {"native": ["Core", "Engine", "Native"], "normie": ["Core", "Engine", "Native", "Orb", "Tools", "Normie"],
              "debug": ["Core", "Engine", "Native", "Orb", "Debug"], "overlay": ["Core", "Engine", "Native", "Overlay"], "settings":["Core", "Engine","Native","Settings"], "header_ax":["Core", "Engine","Native","Orb","Tools","Normie","Island","Debug"]}
    flags = {"native": "M1", "normie": "NORMIE", "debug": "DEBUG", "overlay": "OVERLAY", "settings":"SETTINGS", "header_ax":"HEADER_AX"}
    suites = list(groups) if args.suite == "all" else [args.suite]
    for suite in suites:
        files = []
        for group in groups[suite]:
            root = baseline if group in ["Core", "Orb", "Tools"] else source
            # This app-only bridge depends on Settings, unrelated to these isolated component tests.
            files.extend(sorted(str(p) for p in (root / group).glob("*.swift") if p.name != "CoreSettingsController.swift" or suite == "settings"))
        binary = args.output / (suite + "-selftest")
        result = args.output / suite
        result.mkdir(exist_ok=True)
        log = args.output / (suite + "-compile.log")
        with log.open("w") as handle:
            compiled = subprocess.run(["swiftc", "-swift-version", "6", "-Onone", "-D", flags[suite] + "_SELFTEST",
                "-target", "arm64-apple-macosx26.0", *files, "-o", str(binary)], cwd=repo, stdout=handle, stderr=subprocess.STDOUT)
        if compiled.returncode:
            print(log.read_text()[-14000:])
            raise SystemExit(compiled.returncode)
        subprocess.run([str(binary), str(result)], cwd=repo, check=True)
    print("Offscreen reports and PNGs:", args.output)


if __name__ == "__main__":
    main()
