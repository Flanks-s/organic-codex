"""Verify pulled correction receipts, source fingerprints, frames and per-sample cost gates."""
import argparse
import hashlib
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
E = ROOT / "tools/m1140/evidence"


def read(path):
    return json.loads((E / path).read_text(encoding="utf-8"))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ["validation", "costs", "regression"]:
        p.add_argument("--" + name, required=True)
        p.add_argument("--" + name + "-free", type=float, required=True)
    args = p.parse_args()
    audit = read("r5e-audit.json"); hashes = audit["sourceHashes"]
    assert len(hashes) == 19 and all(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == value for path,
        value in hashes.items())
    verified = []
    def receipt(path, count=None):
        value = read(path)
        if "sourceHashes" in value: assert value["sourceHashes"] == hashes, path
        if "bodyResourcesSHA256" in value:
            assert value["bodyResourcesSHA256"] == audit["baseline"]["shared"][
                "Sources/OrganicShell/BodyPresentation/BodyResources.swift"], path
        if "productSources" in value:
            assert len(value["productSources"]) == 18
            assert all(hashes["Sources/OrganicShell/Panels/" + n] == h for n,
                h in value["productSources"].items()), path
        if "toolHashes" in value:
            assert all(hashlib.sha256((ROOT / "tools/m1140" / n).read_bytes()).hexdigest() == h for n,
                h in value["toolHashes"].items()), path
        assert value.get("sourceUnchanged", True), path
        if count is not None: assert value["checks"] == count and not value["failures"], path
        verified.append(path)
        return value
    for name in ["validation", "costs", "regression"]:
        value = receipt("r5e-final/" + name + "-stage/receipt.json")
        assert value["seconds"] <= 1200 and all(t["exit"] == 0 for t in value["tasks"]), name
    negatives = []
    for name in ["positive", "restored", "no-target", "no-connection", "no-capability", "duplicate-submit",
        "no-rollback", "operation-as-read", "read-failure-swallowed"]:
        path = "r5e-final/d/" + name + "/receipt.json"
        value = receipt(path, 2070 if name in ["positive", "restored"] else None)
        if name not in ["positive", "restored"]:
            assert value["buildExit"] == 0 and value["runExit"] == 1 and value["onlyExpectedCategory"] and value[
                "validNegative"], name
            negatives.append(dict(name=name, checks=value["checks"], failures=len(value["failures"]),
                    category=value["expectedCategory"]))
    suites = []
    for name, folder, count in [
        ("D", "d/restored", 2070), ("C", "c", 714), ("A", "regression/a-check", 371),
        ("B", "regression/b", 30637), ("overlay", "regression/overlay", 2038),
        ("原 mock 成本", "regression/b-cost", 140), ("C live 成本", "c-cost", 140), ("D 动作宿主成本", "d-cost", 140),
    ]:
        value = receipt("r5e-final/" + folder + "/receipt.json", count)
        assert not value.get("stopCondition", False)
        suites.append(dict(name=name, checks=count, failures=0, folder=folder))
    for name in ["release", "wiring", "a-wrapper"]:
        value = receipt("r5e-final/regression/" + name + "/receipt.json")
        assert all(c["exit"] == 0 for c in value["commands"]), name
    wiring = read("r5e-final/regression/wiring/wiring/wiring.json")
    assert wiring["checks"] == 44 and not wiring["failures"]
    suites.append(dict(name="接线", checks=44, failures=0))
    jobs = []
    for job, purpose, free in [
        ("m1140-run-261114-054340-xcf", "诊断：发送夹具尚未完成只读发现，54 项失败", 40.8),
        ("m1140-run-261114-055012-xin", "诊断：恢复偏好指向已移除模型，54 项失败", 40.2),
        ("m1140-run-261114-055138-wbk", "D 2070、C 714 正例及帧", 40.2),
        (args.validation, "D 正例、七负例及恢复", args.validation_free),
        (args.costs, "C live 和 D 动作宿主成本", args.costs_free),
        (args.regression, "release、接线、A/B/overlay、原 mock 成本", args.regression_free),
    ]:
        log = E / "m1140/mac-logs" / (job + ".log")
        records = [json.loads(line[7:]) for line in log.read_text(encoding="utf-8").splitlines() if line.startswith(
                "OCJSON ")]
        assert records, log
        value = records[-1]
        jobs.append(dict(id=job, purpose=purpose, freeGiB=free, queueSeconds=value["queue_s"],
                runSeconds=value["run_s"], exit=value["exit"]))
    frames = []
    for local, remote, count in [
        ("d/restored", f"out/m1140-d/restored-{args.validation}", 32),
        ("c", "out/m1140-c/positive-m1140-run-261114-055138-wbk", 26),
    ]:
        files = sorted((E / "r5e-final" / local / "frames").glob("*.png")); assert len(files) == count
        for file in files:
            assert Image.open(file).size == ((2560, 1704) if file.name.endswith("-2x.png") else (1280, 852)), file
            frames.append(remote + "/frames/" + file.name)
    result = dict(args=vars(args), suites=suites, negatives=negatives, jobs=jobs,
        verifiedReceipts=sorted(set(verified)), framePaths=frames)
    (E / "r5e-results.json").write_bytes((json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    print(json.dumps(dict(receipts=len(result["verifiedReceipts"]), frames=len(frames), negatives=negatives,
            suites=suites), ensure_ascii=False))


if __name__ == "__main__":
    main()
