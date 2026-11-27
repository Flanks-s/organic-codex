"""Bound the ordinary release build to one MBA task; never launch the app."""
import subprocess
import sys

try:
    result = subprocess.run(["zsh", "scripts/build.sh"], timeout=1150)
    raise SystemExit(result.returncode)
except subprocess.TimeoutExpired:
    print("Release build exceeded the 1,150-second task budget.", file=sys.stderr)
    raise SystemExit(124)
