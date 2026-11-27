"""Check the release app's entry receipt, or verify the same harness against a baseline build."""

import argparse
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--app", type=Path, default=Path("build/OrganicShell.app/Contents/MacOS/OrganicShell"))
    parser.add_argument("--baseline", action="store_true")
    parser.add_argument("--escape", action="store_true")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    receipt = output / "panel-entry.json"
    receipt.unlink(missing_ok=True)
    gate = "VERIFY_PANEL_ESCAPE" if args.escape else "VERIFY_PANEL_ENTRY"
    result = subprocess.run([str(args.app.resolve()), "--selftest", str(output)],
                            env=dict(os.environ, **{gate: "1"}), check=False)
    if not receipt.is_file():
        print(f"FAIL panel-entry receipt missing, app exit {result.returncode}")
        return 2
    data = json.loads(receipt.read_text(encoding="utf-8"))
    findings = set(data["findings"])
    baseline_expected = {"sheet.tooltip.haumea", "sheet.selected.haumea", "menu.customize.appearance",
                         "menu.rename.editing", "header.short.overview", "header.brief.settledOverview",
                         "peek.settledOverview"}
    valid = data["checks"] > 0 and data["mockOnly"] is True
    if args.baseline:
        if args.escape:
            baseline_expected = {"escape.tide.overviewClosed", "escape.tide.keepsNotice", "escape.sun.reentryBlocked"}
            valid &= not any(name.startswith("fixture.") for name in findings)
        valid &= result.returncode == 1 and baseline_expected <= findings
    else:
        valid &= result.returncode == 0 and not findings
    print(f"panel-entry {'baseline' if args.baseline else 'candidate'} {'PASS' if valid else 'FAIL'}")
    print(f"{data['checks']} checks")
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
