"""Run a small SERIAL mutation batch inside one task's 20-minute limit."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

allowed = {"six-pages", "nine-bodies", "edge-unclipped", "index-selection", "nil-zero", "resident-tick"}
arguments = sys.argv[1:]
restore = "--restore" in arguments
cases = [arg for arg in arguments if arg != "--restore"]
if arguments.count("--restore") > 1 or not cases or len(cases) > 6 or len(set(cases)) != len(cases) or any(
    case not in allowed for case in cases):
    raise SystemExit("Supply one to six distinct named negative cases, optionally --restore")
sequence = cases + (["restored"] if restore else [])
deadline = time.monotonic() + 1120
root = Path(os.environ["OUT"]) / "m1140-a"
root.mkdir(parents=True, exist_ok=True)
job = os.environ["OC_JOB"]
receipts = []
code = 0
for case in sequence:
    remaining = deadline - time.monotonic()
    if remaining < 120:
        print("Insufficient task budget for another case; no child started: " + case, flush=True)
        code = 75
        break
    env = dict(os.environ, M1140_TASK_BUDGET_SECONDS=str(remaining), PYTHONDONTWRITEBYTECODE="1")
    result = subprocess.run([sys.executable, str(Path(__file__).with_name("check.py")), case], env=env)
    receipt_path = root / (case + "-" + job) / "receipt.json"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8")) if receipt_path.is_file() else {"case": case,
        "missingReceipt": True}
    receipts.append(receipt)
    valid = receipt.get("validNegative") if case in allowed else (receipt.get("buildExit") == 0 and receipt.get(
            "runExit") == 0 and receipt.get("checks", 0) > 0 and not receipt.get("failures"))
    if result.returncode or not valid or not receipt.get("sourceUnchanged"):
        code = result.returncode or 2
        break
summary = {"job": job, "requested": sequence, "cases": receipts, "exit": code,
           "complete": len(receipts) == len(sequence) and code == 0}
(root / ("batch-" + job + ".json")).write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8")
print(json.dumps(summary, ensure_ascii=False), flush=True)
raise SystemExit(code)
