"""Serialized positive / private negative / restored cost gates, one bounded MBA task."""
import os
from pathlib import Path
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[2]
deadline = time.monotonic() + 1150
for case in ["positive", "negative", "restored"]:
    remaining = deadline - time.monotonic()
    if remaining < 10: raise SystemExit(124)
    child = subprocess.Popen([sys.executable, str(root / "tools/m1140/b-cost.py"), "--case", case], cwd=root,
                             env=dict(os.environ, M1140_B_BUDGET=str(remaining - 5)))
    print("cost_caps_child_pid=" + str(child.pid), flush=True)
    result = child.wait(timeout=remaining)
    if result: raise SystemExit(result)
