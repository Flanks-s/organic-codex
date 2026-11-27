"""One serial MBA task, bounded to 1,150 seconds; only recorded child PIDs are stopped."""
import argparse
import json
import os
from pathlib import Path
import sys
import time
from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location("panel_helper", ROOT / "tools/m1140/check.py")
helper = module_from_spec(spec); spec.loader.exec_module(helper)
PLANS = {
    "positive": [["c-check.py", "positive"]],
    "cost": [["c-cost.py"]],
    "negative": [["c-check.py", variant] for variant in ["nil-zero", "mock-fallback", "worked-seed", "context-phase",
            "cross-artifact", "restored"]],
    "regression": [["b-regression.py", "release", "candidate"], ["b-regression.py", "wiring", "candidate"],
        ["b-regression.py", "a", "candidate"],
                   ["b-check.py", "restored"], ["b-check.py", "overlay-positive"], ["b-cost.py", "--case", "positive"]],
}
PLANS["validation"] = PLANS["positive"] + PLANS["cost"] + PLANS["negative"]


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("stage", choices=PLANS)
    args = parser.parse_args(); began = time.monotonic(); deadline = began + 1150
    out = Path(os.environ["OUT"]) / "m1140-c-stages" / os.environ["OC_JOB"]; out.mkdir(parents=True, exist_ok=True)
    result = {"stage": args.stage, "job": os.environ["OC_JOB"], "tasks": []}
    try:
        for index, command in enumerate(PLANS[args.stage]):
            remaining = str(max(1, deadline - time.monotonic() - 15))
            code = helper.run([sys.executable, "tools/m1140/" + command[0], *command[1:]], out / (str(index) + ".log"),
                deadline,
                              dict(os.environ, PYTHONDONTWRITEBYTECODE="1", M1140_B_BUDGET=remaining,
                                   M1140_C_BUDGET=remaining, M1140_TASK_BUDGET_SECONDS=remaining))
            result["tasks"].append({"command": command, "exit": code})
            if code: return code
        return 0
    finally:
        result["seconds"] = time.monotonic() - began
        (out / "receipt.json").write_bytes((json.dumps(result, indent=2) + "\n").encode("utf-8"))
        print(json.dumps(result), flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
