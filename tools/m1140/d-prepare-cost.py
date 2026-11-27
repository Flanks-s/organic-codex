"""Derive a separate D cost driver; leave C/B tools and every timing/readiness expression intact."""
from pathlib import Path

directory = Path(__file__).resolve().parent
text = (directory / "c-cost.py").read_text(encoding="utf-8")
for old, new in [("Live-host costs", "Action-host costs"), ("m1140-c-cost", "m1140-d-cost"),
                 ("M1140_C_BUDGET", "M1140_D_BUDGET"), ("M1140LiveCosts", "M1140ActionCosts"),
                 ("FunctionPanelCCostHost", "FunctionPanelDCostHost")]:
    text = text.replace(old, new)
text = text.replace('ROOT / "tools/m1140/PanelsCRecordedData.swift"]',
    'ROOT / "tools/m1140/PanelsCRecordedData.swift", ROOT / "tools/m1140/PanelsDRecordedData.swift", ROOT '
        '/ "tools/m1140/PanelsDCostHost.swift"]')
text = text.replace('"--add", "tools/m1140/PanelsCRecordedData.swift"]',
    '"--add", "tools/m1140/PanelsCRecordedData.swift", "--add", "tools/m1140/PanelsDRecordedData.swift", '
        '"--add", "tools/m1140/PanelsDCostHost.swift"]')
(directory / "d-cost.py").write_bytes(text.encode("utf-8"))
