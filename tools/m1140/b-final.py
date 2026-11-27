"""Track text correction: B, one private negative, restored frames, overlay and unchanged regressions."""
import os
from pathlib import Path
import subprocess
import sys
import time
root = Path(__file__).resolve().parents[2]
deadline = time.monotonic() + 1150
steps = [["b-batch.py", "positive", "track-text-unbounded", "restored", "overlay-positive"],
         ["b-regression.py", "release", "candidate"],
         ["b-regression.py", "wiring", "candidate"],
         ["b-regression.py", "a", "candidate"]]
for step in steps:
    remaining = deadline - time.monotonic()
    if remaining < 10: raise SystemExit(124)
    child = subprocess.Popen([sys.executable, str(root / "tools/m1140" / step[0]), *step[1:]], cwd=root,
                             env=dict(os.environ, M1140_B_BUDGET=str(remaining - 5)))
    print("final_child_pid=" + str(child.pid), flush=True)
    result = child.wait(timeout=remaining)
    if result: raise SystemExit(result)
