"""Serialize related checks inside one bounded MBA task; never submit another job."""
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
groups = {
    "candidate-release": [("compact", "baseline"), ("compact", "candidate"), ("release", "candidate"), ("wiring",
            "candidate"), ("a", "candidate")],
    "baseline-release": [("release", "baseline"), ("wiring", "baseline"), ("phase", "baseline"), ("phase", "candidate"),
        ("phase-task", "baseline"), ("phase-task", "candidate")],
    "compact-pair": [("compact", "baseline"), ("compact", "candidate")],
    "phase-pair": [("phase", "baseline"), ("phase", "candidate")],
    "host-pair": [("phase-host", "baseline"), ("phase-host", "candidate"), ("pressure", "baseline"), ("pressure",
            "candidate")],
    "pressure-pair": [("pressure", "baseline"), ("pressure", "candidate")],
    "task-pair": [("phase-task", "baseline"), ("phase-task", "candidate")],
}
deadline = time.monotonic() + min(1150, float(os.environ.get("M1140_B_BUDGET", "1150")))
for suite, version in groups[sys.argv[1]]:
    remaining = deadline - time.monotonic()
    if remaining < 10: raise SystemExit(124)
    env = dict(os.environ, M1140_B_BUDGET=str(remaining - 5))
    child = subprocess.Popen([sys.executable, str(root / "tools/m1140/b-regression.py"), suite, version], cwd=root,
        env=env)
    print("stage_child_pid=" + str(child.pid), flush=True)
    result = child.wait(timeout=remaining)
    if result: raise SystemExit(result)
