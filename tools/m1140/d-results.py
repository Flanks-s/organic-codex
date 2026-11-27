"""Read final receipts, verify all product fingerprints and build the report's data input."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
E = ROOT / "tools/m1140/evidence"
V, L, R = ["m1140-run-261114-" + suffix for suffix in ["035804-yto", "042423-yjd", "044843-mcu"]]


def read(path): return json.loads((E / path).read_text(encoding="utf-8"))


def main():
    audit = read("d-final-audit.json"); hashes = audit["sourceHashes"]
    assert len(hashes) == 19 and all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p,
        h in hashes.items())
    verified, suites = [], []
    def receipt(path, count=None):
        value = read(path)
        if "sourceHashes" in value: assert value["sourceHashes"] == hashes, path
        if "productSources" in value:
            assert len(value["productSources"]) == 18
            assert all(hashes["Sources/OrganicShell/Panels/" + n] == h for n, h in value["productSources"].items())
        assert value.get("sourceUnchanged", True), path
        if count is not None: assert value["checks"] == count and not value["failures"], path
        verified.append(path); return value
    for stage in ["validation", "live", "regression"]:
        value = receipt("d-final/" + stage + "-stage/receipt.json")
        assert all(t["exit"] == 0 for t in value["tasks"]), stage
    positive = f"d-final/d/positive-{V}/receipt.json"
    restored = f"d-final/d/restored-{V}/receipt.json"
    receipt(positive, 1192); receipt(restored, 1192)
    negatives = []
    for name in ["no-target", "no-connection", "no-capability", "duplicate-submit", "no-rollback"]:
        path = f"d-final/d/{name}-{V}/receipt.json"; value = receipt(path); negatives.append(path)
        assert value["buildExit"] == 0 and value["runExit"] == 1 and value["onlyExpectedCategory"] and value[
            "validNegative"]
    for name, folder, count, remote in [
        ("D", f"d/{'positive-' + V}", 1192, f"out/m1140-d/positive-{V}"),
        ("C", "c", 677, f"out/m1140-c/positive-{L}"),
        ("A", "regression/a-check", 371, f"out/m1140-a/restored-{R}"),
        ("B", "regression/b", 30637, f"out/m1140-b/restored-{R}"),
        ("overlay", "regression/overlay", 2038, f"out/m1140-b/overlay-positive-{R}"),
        ("原 mock 成本", "regression/b-cost", 140, f"out/m1140-b-cost/positive-{R}"),
        ("C live 成本", "c-cost", 140, f"out/m1140-c-cost/{L}"),
        ("D 动作宿主成本", "d-cost", 140, f"out/m1140-d-cost/{L}")]:
        value = receipt("d-final/" + folder + "/receipt.json", count)
        assert not value.get("stopCondition", False)
        suites.append({"name": name, "checks": count, "failures": 0, "path": remote})
    for name in ["release", "wiring", "a-wrapper"]:
        value = receipt("d-final/regression/" + name + "/receipt.json")
        assert all(c["exit"] == 0 for c in value["commands"]), name
    wiring = read("d-final/regression/wiring/wiring/wiring.json")
    assert wiring["checks"] == 44 and not wiring["failures"]
    suites.append({"name": "接线", "checks": 44, "failures": 0,
            "path": f"out/m1140-b-regression/wiring-candidate-{R}/wiring/wiring.json"})
    jobs = []
    for job, purpose, free in [
        ("m1140-run-261114-022131-fwf", "诊断：专项工具 host 协议类型错误，修正后重跑", 45.3),
        ("m1140-run-261114-031104-lfs", "诊断：1147 正例、五负例及恢复；非最终源码", 44.6),
        (V, "最终 D 正例、五负例及恢复", 40.7),
        (L, "C 正例、C live 与 D 动作宿主成本", 40.5),
        (R, "release、接线、A/B/overlay、原 mock 成本", 40.9)]:
        log = E / "m1140/mac-logs" / (job + ".log")
        candidates = [line[7:] for line in log.read_text(encoding="utf-8",
                errors="strict").splitlines() if line.startswith("OCJSON ")]
        assert candidates, log
        value = json.loads(candidates[-1])
        jobs.append({"id": job, "purpose": purpose, "freeGiB": free, "queueSeconds": value["queue_s"],
                "runSeconds": value["run_s"], "exit": value["exit"]})
    frame_paths = []
    for local, remote, expected in [
        (f"d-final/d/restored-{V}/frames", f"out/m1140-d/restored-{V}/frames", 28),
        ("d-final/c/frames", f"out/m1140-c/positive-{L}/frames", 26)]:
        files = sorted((E / local).glob("*.png")); assert len(files) == expected, local
        from PIL import Image
        for file in files:
            expected_size = (2560, 1704) if file.name.endswith("-2x.png") else (1280, 852)
            assert Image.open(file).size == expected_size, file
            frame_paths.append(remote + "/" + file.name)
    result = {"positive": positive, "restored": restored, "negatives": negatives,
        "verifiedReceipts": sorted(set(verified)), "suites": suites, "jobs": jobs,
        "costSummaries": {"原 mock": "d-final/regression/b-cost/summary.json", "C live": "d-final/c-cost/summary.json",
            "D 动作宿主": "d-final/d-cost/summary.json"},
        "framePaths": frame_paths, "frameNotes":
            "最终 D 恢复帧 28 张，C 真数据及缺值帧 26 张；PNG 原生尺寸逐项核对。D 的输入保留帧使用本地编辑探针，原始草稿值与 AX 完整保留；短标题编辑框仍按既有原位编辑器水平容纳文字，"
            "不宣称已接通 Rename。真实玻璃交 Claude 实窗。"}
    (E / "d-results.json").write_bytes((json.dumps(result, indent=2, ensure_ascii=False) + "\n").encode("utf-8"))
    print(json.dumps({"receipts": len(result["verifiedReceipts"]), "products": len(hashes), "frames": len(frame_paths),
            "suites": suites}, ensure_ascii=False))


if __name__ == "__main__": main()
