#!/usr/bin/env python3
# RETIRED (#186, 2026-11-12): replaced by tools/m11/component-check.py settings, overlay (overlay: debt #75). Kept, not deleted (#181).
"""M8 group 1: pin committed dependencies and compile Settings/Overlay only in a private checkout."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys


def baseline_settings_tests(text):
    # Keep production files exactly at the requested commit. The old source has neither
    # the windowless owner seam nor the injectable native color panel; those checks run
    # in the final suite, and color ownership also has a separate pre-fix seam repro.
    start = text.index("@MainActor private final class Group1ColorPanel:")
    end = text.index("@MainActor enum SettingsGroup1Verification", start)
    text = text[:start] + text[end:]
    text = text.replace("        colors(defaults,check:check)\n", "")
    start = text.index("    private static func lifecycle(")
    end = text.index("    private static func sheets(", start)
    legacy = """
    private static func lifecycle(_ defaults:UserDefaults,check:(Bool,String)->Void) async {
        let source=Group1SettingsSource(),session=SettingsSession(source:source,preferences:SettingsPreferences(defaults:defaults))
        let retired=NativeSettingsWorkbench(session:session);retired.automaticallyLoads=false;retired.loadViewIfNeeded()
        session.go("general");session.go("appearance");retired.stop();let pane=session.pane
        let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:0,context:nil,characters:"[",charactersIgnoringModifiers:"[",isARepeat:false,keyCode:33)!
        check(!retired.routeKey(key) && session.pane == pane,"G1 f154 retired workbench ignores keyboard navigation after close")
    }
"""
    text = text[:start] + legacy + text[end:]
    return text[:text.index("    private static func colors(")] + "}\n#endif\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", help="Commit to pin (default: current HEAD).")
    parser.add_argument("--output", type=Path, required=True, help="Artifacts and a new private repo; repo/ must not exist.")
    parser.add_argument("--before", action="store_true", help="Keep production at baseline; expect regression failures.")
    parser.add_argument("--prepare-only", action="store_true", help="Prepare and verify source isolation without compiling.")
    parser.add_argument("--build", action="store_true", help="Also build the app in the private checkout; never launch it.")
    args = parser.parse_args()
    if args.before and args.build:
        parser.error("--before is a regression repro, not an app build")
    source = Path(__file__).resolve().parents[3]
    base = subprocess.check_output(["git", "rev-parse", args.baseline or "HEAD"], cwd=source, text=True).strip()
    output = args.output.resolve()
    if output == source or output.is_relative_to(source):
        parser.error("--output must be outside the shared repository")
    output.mkdir(parents=True, exist_ok=True)
    private = output / "repo"
    if private.exists():
        parser.error("repo/ already exists; use a new --output to preserve earlier evidence")
    subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(source), str(private)], check=True)
    subprocess.run(["git", "checkout", "--quiet", "--detach", base], cwd=private, check=True)
    target = private / "Sources/OrganicShell"
    if args.before:
        settings = (source / "Sources/OrganicShell/Settings/SettingsGroup1Verification.swift").read_text()
        (target / "Settings/SettingsGroup1Verification.swift").write_text(baseline_settings_tests(settings))
        shutil.copy2(source / "Sources/OrganicShell/Overlay/OverlayGroup1Verification.swift",
                     target / "Overlay/OverlayGroup1Verification.swift")
        for suite, flag in [("Settings", "await SettingsGroup1Verification.run(check:{check($0,$1)},png:{png($0,$1,output)})"),
                            ("Overlay", "try OverlayGroup1Verification.run(output:output,check:{ check($0,$1) })")]:
            path = target / suite / (suite + "Verification.swift")
            text = path.read_text()
            if suite == "Settings":
                anchor = "        SettingsNativeAppearanceVerification.run(check:{check($0,$1)})"
                if anchor not in text:
                    raise ValueError("Unsupported baseline Settings entry point")
                text = text.replace(anchor, anchor + "\n        " + flag)
            else:
                anchor = '        let report = (["Overlay verification:'
                if anchor not in text:
                    raise ValueError("Unsupported baseline Overlay entry point")
                at = text.index(anchor)
                text = text[:at] + "        " + flag + "\n" + text[at:]
            path.write_text(text)
        changed = subprocess.check_output(["git", "diff", "--name-only"], cwd=private, text=True).splitlines()
        if set(changed) != {"Sources/OrganicShell/Settings/SettingsVerification.swift",
                           "Sources/OrganicShell/Overlay/OverlayVerification.swift"}:
            raise ValueError("Baseline production source must remain unchanged")
    else:
        for name in ["Settings", "Overlay"]:
            shutil.copytree(source / "Sources/OrganicShell" / name, target / name, dirs_exist_ok=True)
    print("BASELINE:", base, "\nPRIVATE_COPY:", private, flush=True)
    if args.prepare_only:
        return
    for suite in ["settings", "overlay"]:
        result = subprocess.run([sys.executable, "Sources/OrganicShell/Debug/.verify_components.py", suite,
                                 "--baseline", base, "--output", str(output / suite)], cwd=private)
        report = output / suite / suite / "verification.txt"
        if args.before:
            # An expected behavioral red run must have a report: compiler failures are not evidence.
            expected = report.is_file() and ("G1 f" in report.read_text())
            if result.returncode == 0 or not expected:
                raise SystemExit("Expected behavioral regression findings, not a successful run or compiler failure")
            print("EXPECTED BASELINE REGRESSIONS:", suite, flush=True)
        elif result.returncode:
            raise SystemExit(result.returncode)
    if args.build:
        with (output / "release-build.log").open("w") as log:
            subprocess.run(["swift", "build", "-c", "release", "--scratch-path", ".build-sol"],
                           cwd=private, stdout=log, stderr=subprocess.STDOUT, check=True)


if __name__ == "__main__":
    main()
