"""Bounded, serial read/operation-error correction batches; no windows or network."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("d_stage", Path(__file__).with_name("d-stage.py"))
stage = importlib.util.module_from_spec(spec); spec.loader.exec_module(stage)
stage.PLANS = {
    "positive": [["d-check.py", "positive"], ["c-check.py", "positive"]],
    "validation": [["d-check.py", case] for case in ["positive", "no-target", "no-connection", "no-capability",
            "duplicate-submit", "no-rollback", "operation-as-read", "read-failure-swallowed", "restored"]],
    "costs": [["c-cost.py"], ["d-cost.py"]],
    "regression": stage.PLANS["regression"],
    "c": [["c-check.py", "positive"]],
}
if __name__ == "__main__":
    raise SystemExit(stage.main())
