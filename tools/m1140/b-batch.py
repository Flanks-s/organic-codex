"""Sequential subcases share one 1150-second task budget and stop on first invalid receipt."""
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
deadline = time.monotonic() + min(1150, float(os.environ.get("M1140_B_BUDGET", "1150")))
cases = ["release-hd", "upscaled", "context-phase", "tick", "uncancelled", "overlap", "restored", "cost"]
if len(sys.argv) > 1:
    cases = sys.argv[1:]
for case in cases:
    remaining = deadline - time.monotonic()
    if remaining < 5: raise SystemExit(124)
    env = dict(os.environ, M1140_B_BUDGET=str(remaining - 3))
    command = [sys.executable, str(root / "tools/m1140/b-cost.py")] if case == "cost" else [sys.executable,
        str(root / "tools/m1140/b-check.py"), case]
    child = subprocess.Popen(command, cwd=root, env=env)
    print("batch_child_pid=" + str(child.pid), flush=True)
    result = child.wait(timeout=remaining)
    if result: raise SystemExit(result)
