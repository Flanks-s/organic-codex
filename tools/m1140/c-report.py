"""Assemble the C handoff from downloaded receipts; UTF-8/LF, original prefix guarded."""
from pathlib import Path
import hashlib
import json
import re

ROOT = Path(__file__).resolve().parents[2]
E = ROOT / "tools/m1140/evidence"
VALIDATION = "m1140-run-261114-011616-agk"
REGRESSION = "m1140-run-261114-012238-jzm"
DOC = ROOT / "docs/reference/M11-40-PANELS-PLAN-SOL-261112.md"


def read(path):
    return json.loads(path.read_text(encoding="utf-8"))


def main():
    audit = read(E / "c-initial-audit.json")
    before = DOC.read_bytes()
    assert hashlib.sha256(before[:audit["reportPrefixBytes"]]).hexdigest() == audit["reportPrefixSHA256"]
    validation = E / "c-final-validation"
    c = read(validation / ("restored-" + VALIDATION) / "report.json")
    positive = read(validation / ("positive-" + VALIDATION) / "report.json")
    cost = read(E / "c-final-live-cost/summary.json")
    cost_receipt = read(E / "c-final-live-cost/receipt.json")
    reg = E / "c-final-regression"
    b = read(reg / "b/receipt.json"); overlay = read(reg / "overlay/receipt.json")
    a = read(reg / "a-check/receipt.json"); old_cost = read(reg / "b-cost/receipt.json")
    for name in ["release", "wiring", "a-wrapper"]:
        assert all(x["exit"] == 0 for x in read(reg / name / "receipt.json")["commands"])
    assert not c["failures"] and c["checks"] == 677 and len(c["frames"]) == 26
    assert b["checks"] == 30637 and not b["failures"]
    assert overlay["checks"] == 2038 and not overlay["failures"]
    assert a["checks"] == 371 and not a["failures"]
    assert old_cost["checks"] == cost_receipt["checks"] == 140
    assert not old_cost["failures"] and not cost_receipt["failures"] and not cost_receipt["stopCondition"]
    hashes = cost_receipt["sourceHashes"]
    assert len(hashes) == 16
    assert all(hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
    receipts = list(validation.glob("*" + VALIDATION + "/receipt.json")) + [E / "c-final-live-cost/receipt.json",
        reg / "b/receipt.json", reg / "overlay/receipt.json", reg / "b-cost/receipt.json"]
    assert len(receipts) == 11
    for p in receipts:
        r = read(p); assert r["sourceHashes"] == hashes and r["sourceUnchanged"], p
    for name, h in a["productSources"].items():
        assert hashes["Sources/OrganicShell/Panels/" + name] == h
    stream = "Sources/OrganicShell/BodyPresentation/BodyPhaseStream.swift"
    assert hashes[stream] == "32cce9abd7d8f9281d5051375f6c55c936bd1e7cf93f735779008826bc506d3c"
    assert cost_receipt["bodyResourcesSHA256"] == "9ecb7e63cf030a7736258971e64ffaa0f08a062b49b82913406b40db0bdfecda"
    outside = [p for p in (ROOT / "Sources/OrganicShell").rglob("*.swift") if "Panels" not in p.parts and any(
            n in p.read_text(encoding="utf-8") for n in ["FunctionPanelProjection", "FunctionPanelLiveHost"])]
    assert not outside
    lines = ["### C.4 最终验收与成本", "",
        "最终当前源码：C 正例及恢复各 **677／0**；release 通过；宿主接线 **44／0**；原 A **371／0**、B **30637／0**、overlay **2038／0**、原成本 "
        "**140／0** 全过；live 成本 **140／0**。按每套最终正例只计一次，共 **34047／0**，不把恢复复跑或负例的预期失败加进正例。", "",
        "八场景和五类代表缺值帧均为真实 reducer 投影，共26张（每类1×／2×）；PNG原生尺寸逐个核对为1280×852／2560×1704。缩略检查及 used-only 球内裁图确认两条文字完整。"
        "真实玻璃、实窗交互及 #218 第3条仍交 Claude／步骤 E。", "",
        "新增8项检查保留绘制时的同一 CTLine，核对 used-only 两行 source、实际 glyph／fragment 框完整、无截断和互不相交；未依赖AX中存在完整字符串就判画面可读。", "",
        "| 编译负例 | 检查数 | 预期失败数 | 唯一类别 | build／binary exit |", "| --- | ---: | ---: | --- | --- |"]
    for name in ["nil-zero", "mock-fallback", "worked-seed", "context-phase", "cross-artifact"]:
        r = read(validation / (name + "-" + VALIDATION) / "receipt.json")
        assert r["buildExit"] == 0 and r["runExit"] == 1 and r["validNegative"] and r["onlyExpectedCategory"]
        lines.append(f"| {name} | {r['checks']} | {len(r['failures'])} | `{r['expectedCategory']}` | 0／1 |")
    lines += ["", "五个负例均只修改私有包副本；恢复677／0，工作区源未变，原有断言未改。缺值、mock回落、Worked seed、Context充phase、跨thread artifact均有编译负例；"
        "其余页的真实缺口、断线、无turnID／无计划、缺child、截断／旧diff证明、同revision零重算、来源切换、child revision、真实改名／完成后保留导航及静止零新帧均有正例。",
        "", "成本沿用 `PanelsBCostMain.swift` 的时钟、就绪定义、5个冷进程及15次热重开／关闭计划。私有副本只换宿主构造，并把反转的固定serial=3匹配改为最新真实bridge "
        "serial匹配；计时点、质量、等待与门均未改。成本宿主保持B的‘stage减运动、phase反转显式动画’探针；普通C宿主Reduce Motion给phase终态。进程冷，不清磁盘缓存；包含重放／"
        "投影／资源构造到请求的offset。", "", "| 倍率／指标 | n | p50 ms | p90 ms | max ms | 上限／判定 | 原样本 ms |",
        "| --- | ---: | ---: | ---: | ---: | --- | --- |"]
    metrics = [("cold/firstTexture", "冷首贴图", 120), ("cold/firstHD", "冷首HD", 200), ("warm/firstHD", "热重开HD", 150),
        ("cold-close/released", "冷关释放", 20), ("warm-close/released", "热关释放", 20)]
    for scale in [1, 2]:
        for key, label, limit in metrics:
            v = cost["costs"][f"{scale}x/{key}"]
            gate = f"≤{limit}，逐样本过" if scale == 2 else "只记、不判"
            raw = ", ".join(f"{x:.3f}" for x in v["raw_ms"])
            lines.append(
        f"| {scale}×／{label} | {v['n']} | {v['p50_ms']:.3f} | {v['p90_ms']:.3f} | {v['max_ms']:.3f} | {gate} | {raw} |")
    lines += ["", "2× 每个样本均过门，不按p50判。每倍率5个全新进程、15次热重开、5次冷关及15次热关，关闭后HD／imageTasks／phaseJobs／phasePending均为0。", "",
        "| 倍率 | HD峰值 B（逐进程） | HD max B | sprite max B | map max B |", "| --- | --- | ---: | ---: | ---: |"]
    for scale in [1, 2]:
        rs = [r for r in cost["records"] if r["scale"] == scale]
        assert len(rs) == 5 and all(all(v == 0 for v in row["releaseState"].values(
                )) for r in rs for row in r["samples"] if row["kind"] in ["cold-close", "warm-close"])
        lines.append(f"| {scale}× | " + ", ".join(str(r["peakHD"]) for r in rs) +
          f" | {max(r['peakHD'] for r in rs)} | {max(r['peakSprite'] for r in rs)} | {max(r['peakMap'] for r in rs)} |")
    lines += ["", "2× HD峰值≤16 MiB（16777216 B）；`BodyResources.swift` 实际上限及SHA未变，原探针仍验证恰好16 MiB可预约、再多1 B拒绝。sprite／"
        "map按既有共享缓存保留，关闭归零的是HD lease及任务，不伪称清空整个共享缓存。", "",
        f"完整原精度样本及反转／首位图／释放记录：`out/m1140-c-cost/{VALIDATION}/summary.json`，逐进程`s1-0.json`…`s1-4.json`、"
        f"`s2-0.json`…`s2-4.json`。上表仅保留3位小数；实际门直接用原始Double，不四舍五入过门。", "", "投影本身只记、不设门（不含录制重放）："]
    for label, report in [("正例", positive), ("恢复", c)]:
        values = {k: v for row in report["projectionTimingSamples"] for k, v in row.items()}
        lines.append(f"- {label}首次 `{values['firstMS']:.6f} ms`；真实compacted事件后的增量 `{values['incrementalMS']:.6f} ms`。")
    lines += ["", "正常产品无新入口／调用方：新增宿主、投影的引用全部位于Panels或专项工具。没有注册全局观察者或timer；同revision不构建、不访问items；phase／sprite回调不重新投影。"
        "共享路径0行，Stream及BodyResources源字节未变，故本轮不强制Column Work等#144计时，也不重复phase共享回归。", "", "新增工具文件（均为本轮新增，UTF-8／LF）：", "",
        "| 文件 | 行数 |", "| --- | ---: |"]
    tool_names = ["PanelsCRecordedData.swift", "PanelsCCheckMain.swift", "c-check.py", "c-cost.py", "c-stage.py",
        "c-report.py", "c-positive.zsh", "c-cost.zsh", "c-negative.zsh", "c-validation.zsh", "c-regression.zsh"]
    for name in tool_names:
        lines.append(f"| `tools/m1140/{name}` | {len((ROOT / 'tools/m1140' / name).read_bytes().splitlines())} |")
    lines += ["", "原有A／B／成本／接线工具未改。`c-report.py`只读下载回执和源码信息，生成本报告，写入前后保护原957行的字节及UTF-8／LF。", "",
        "过程记录：232536-rkr的新AX长表达式类型检查超时，拆成等价小段修复；003527-rfg先过C669／0与live140／0，005958-zam过全套旧回归。随后缩略检查发现used-only"
        "资格文字被截，补同一CTLine的完整可见检查，再用011616-agk及012238-jzm按当前源码复验。过程回执不冒充最终指纹。", ""]
    text = before.decode("utf-8")
    start = text.index("### C.4 ")
    dstart = text.index("### C.5 ", start)
    d = text[dstart:].split("### C.6 ")[0].rstrip()
    tail = ["", "### C.6 MBA任务表", "",
"所有任务均经主树mac.ps1，item=m1140，build／heavy／detach／wait-min 480；逐个结束后再交下一项。free_gib交前均≥20，没有clean或绕过空间门。单项运行均<20分钟；排队时间另列。",
        "", "| 任务 | 交前GiB | 排队s | 运行s | 结论 |", "| --- | ---: | ---: | ---: | --- |"]
    job_specs = [("m1140-run-261113-232536-rkr", 47.9, "首编译，AX长表达式超时；已修"), ("m1140-run-261114-003527-rfg", 47.4,
            "C669、live140、五负例／恢复；显示修正前"), ("m1140-run-261114-005958-zam", 47.6, "旧回归全过；显示修正前"), (VALIDATION, 47.5,
            "最终C677、live140、五负例／恢复；26张新帧"), (REGRESSION, 47.5, "最终release／44／371／30637／2038／原140")]
    for job, free, detail in job_specs:
        log = E / "m1140/mac-logs" / (job + ".log")
        metas = [json.loads(row[len("OCJSON "):]) for row in log.read_text(encoding="utf-8").splitlines(
                ) if row.startswith("OCJSON ")]
        m = metas[-1]
        tail.append(f"| `{job}` | {free} | {m['queue_s']} | {m['run_s']} | exit {m['exit']}；{detail} |")
    tail += ["",
        "ship只用主树工具；测量保护等待照工具规则执行。当前最终产品验收后没有再改产品源码。没有git写操作、推送、CI、另起codex exec、桌面窗口／鼠标操作或其它worktree写入；没有停止任何非本线进程。",
        "", "### C.7 最终帧路径", "",
        f"MBA目录：`out/m1140-c/restored-{VALIDATION}/frames/`。同源码正例另有`out/m1140-c/positive-{VALIDATION}/frames/`。"
        f"以下26张均已拉回并检查原生尺寸及缩略图：", ""]
    for name in c["frames"]:
        tail.append("- `" + name + "`")
    tail += ["",
        "Context-only-used的最终裁图确认“900 tokens”和“Limit not provided”完整分行；比例已知时仍照默认在球内，未改口味项。Library真实预览能力缺口仍明确占位；"
        "未修改Tools selectedID。", "", "### C.8 最终13＋3个产品指纹", "",
        "最终C正负例／恢复7份、live成本1份、B／overlay／原成本3份，共11份回执，以下16项SHA-256均与本地逐个相等；A另含15项Panels指纹逐个相等。release／接线在同一未变源码镜像内执行。",
        "", "| 产品文件 | SHA-256 |", "| --- | --- |"]
    for name, h in hashes.items():
        tail.append(f"| `{name}` | `{h}` |")
    tail += ["", "共享账本文件未动：`BodyResources.swift` SHA-256=`" + cost_receipt["bodyResourcesSHA256"] + "`。", ""]
    result = text[:start] + "\n".join(lines) + "\n" + d + "\n" + "\n".join(tail)
    encoded = result.encode("utf-8")
    assert encoded[:audit["reportPrefixBytes"]] == before[:audit["reportPrefixBytes"]]
    assert b"\r" not in encoded and not encoded.startswith(b"\xef\xbb\xbf")
    assert "??" not in result[start:] and "\ufffd" not in result[start:]
    DOC.write_bytes(encoded)
    assert DOC.read_text(encoding="utf-8") == result
    (E / "c-final-audit.json").write_bytes((json.dumps({"validation": VALIDATION, "regression": REGRESSION,
            "receipts": 11, "products": 16, "sourceHashes": hashes, "normalProductCallers": [],
            "originalPrefixUnchanged": True, "reportUTF8LF": True}, indent=2) + "\n").encode("utf-8"))
    print("C report written; 11 x 16 hashes, original prefix, UTF-8/LF verified")


if __name__ == "__main__":
    main()
