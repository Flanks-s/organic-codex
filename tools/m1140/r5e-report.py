"""Append the correction report as UTF-8/no BOM/LF, keeping its full original prefix."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
E = ROOT / "tools/m1140/evidence"


def read(path):
    return json.loads((E / path).read_text(encoding="utf-8"))


def main():
    config, audit = read("r5e-results.json"), read("r5e-audit.json")
    report = ROOT / "docs/reference/M11-40-PANELS-PLAN-SOL-261112.md"
    baseline = audit["baseline"]; prefix = report.read_bytes()[:baseline["reportBytes"]]
    assert hashlib.sha256(prefix).hexdigest() == baseline["reportSHA"]
    lines = ["", "## 第五轮修正（操作错误与读取失败）", "", "基点 `5e4b4f2`；本节记录 2026-11-14 的修正与 MBA 回执。共享文件 0 行，正式入口仍未安装。", "",
        "### 1. 判法与错误呈现", "",
        "`operationError` 是最近一次对话操作／Core 错误，不能证明已载入资料读取失败。`availability` 先认显式的 `sources.historyError`；只有 "
            "`historyLoaded == false && loading == false` 时，`operationError` 才能证明尚未读到历史。已读历史在操作报错、乃至刷新中仍保留 items、"
            "satellites、changes；Goal 和有来源的压缩记录也不再被操作错误清掉。Library／Outputs 继续各自服从 artifact 来源的五态，不由通用操作错误覆盖。"
            "既有显式读源断线的 `Disconnected` 分支保留，不从对话错误推断断线。", "",
        "Context 完全独立：只读 `exactTokensUsed` 和 `contextLimit`，不看 `operationError`、history/loading 或连接状态。"
            "两个字段有效才给比值；只有 used 时保留实际 token 数并显示 `Limit not provided`；没有 used 时 `Not provided`，不补 0。真正从未读到历史的失败夹具也不"
            "把 Context 伪造成历史读取失败。", "",
        "State 的业务状态照常显示。对话错误沿用专项宿主底部已有消息卡的位置 `(66,672,491,56)`，上面用和 State 相同的小号灰标签写 `State · Conversation "
            "error`，下一行显示 `operationError` 原文，尾截断；AX 保留全文。它处于 #213 既有覆盖区内，各页都可见，不挤掉 Overview 的资料或动作。若动作回执与对话错误相同只画一"
            "次；不同则在末行另显示动作回执。Dismiss 只清动作回执，不篡改 Conversation 的实际错误。A／B mock 的画面和入口语义不变。", "",
        "### 2. 文件与行数", "", "相对本轮基点的增删行及当前总行数如下；报告仅在原有字节之后追加。", "", "| 文件 | 增／删 | 当前行数 |", "| --- | ---: | ---: |"]
    changes = subprocess.check_output(["git", "diff", "--numstat"], cwd=ROOT, text=True).splitlines()
    rows = []
    for line in changes:
        added, removed, name = line.split("\t")
        if name != report.relative_to(ROOT).as_posix(): rows.append((name, added + "／" + removed))
    for name in subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT,
        text=True).splitlines():
        if name.startswith("tools/m1140/"): rows.append((name, "新增"))
    for name, delta in sorted(rows):
        lines.append(f"| `{name}` | {delta} | {len((ROOT / name).read_bytes().splitlines())} |")
    lines += ["", "产品只改 `FunctionPanelProjection.project`、`FunctionPanelLivePresentation`／`FunctionPanelReadSources` "
        "的纯值字段，以及 `FunctionPanelView.render` 的消息呈现。未改动作业务写口。工具新增 `PanelsDReadErrors`、两个私有变异、串行批次和本地回执／报告审计。"
        "`BodyPhaseStream`、`BodyResources`、Package、App、Scene 和所有共享检查工具均未改。", "",
        "只读核对在飞线：`m1138-attach` 在 Core／Panels 没有接口改动；`m1146` 在改 `OrganicWindow` 的 Browser 宿主段，未改本轮读取的身份失败 "
            "catch 或 Core 写口。本轮不修改、覆盖或调用这些在飞新接口。", "",
        "### 3. #226 夹具拆分与 C 断言逐条核对", "",
        "读取失败：`FunctionPanelCRecordedData(recordHistory: false)` 只创建真实 Store／Conversation 的路由身份，不回放任何历史；items、"
            "token、satellites、changes 从未被载入。只设 `sources.historyError` 和 model／artifacts 的显式 `.failed`，不设 "
            "`operationError`。操作出错：仍由录制事件经 Store.apply／EventReducer 载入真实历史，只设置 `operationError`，不把任何读取来源设为失败。"
            "两者没有相互混设。", "",
        "| C 原项／原前提 | 本轮新前提／断言 | 理由 |", "| --- | --- | --- |",
        "| `failed` 原前提：已读历史＋operationError＋artifact/model failed | 改为未读历史＋明确 historyError＋artifact/model "
            "failed，operationError 为 nil | 原夹具把两种失败绑在一起，无法证明失败来源。 |",
        "| `live.values.explicit-state.failed`：Library 以 Couldn’t load 开头 | 断言表达式不变，现只由显式 artifact failed 满足 | "
            "保留读取失败，移除对通用操作错误的依赖。 |",
        "| `live.values.no-unknown-empty.failed`：Library 的 value 为 nil | 断言表达式不变；未读且显式失败，不能已知空 | 保留缺值与已知空的区别。 |",
        "| 各页 `live.values.no-zero.failed*`：Context 不等于 0 | 断言表达式不变；未读夹具无 token，新增断言精确为 unavailable／Not "
            "provided | Context 只服从 token 来源，不能被历史失败冒充，也不能补 0。 |",
        "| failed 各页 noMock／Worked 不得取 seed | 原断言全部不变 | 读取失败不能回落 mock 或伪造 Worked。 |",
        "| 原来没有独立 operation-error 夹具 | 每页新增 Context=原值、3 children、Goal、当前资料 Known、错误原文与语义可见 | 单独抓出已读资料被操作错误抹掉的回归。 |",
            "",
  "C 原有 677 项表达式未删除、未放宽；只改上述 failed 的构造前提。新增 37 项：读取失败 17 项（其中 5 项 token 缺值归原 `live.values` 类），独立操作错误 20 项。最终 C 714／0。",
            "",
        "### 4. D 新检查与真实错误路径", "",
        "D 保留原 1192 项，新增 878 项：`reads.operation-error` 734（包括 4 张新帧写入），`reads.failure` 144。四种错误各自查八场景（Overview、"
            "Customize、Subagents、hover、Library、Files、Background、Outputs）×1×／2×：Context、children、Library、Files、"
            "Background、Outputs、Goal/model/压缩来源与错误前完全相等；错误原文实际画在卡内、State 标签和 AX 可见；没有页面变成 Couldn’t load。先断言所有资料非空，"
            "避免空值相等蒙混过关。读取失败另查显式来源与未读历史错误两个分支，均不吞成 unloaded、已知空或 0。", "",
        "| 错误 | 真实路径与隔离方式 |", "| --- | --- |",
        "| 父 Stop 被拒 | 原 D 内存 transport 返回 409；ActionOwner → Runtime.interrupt → report，恰好一个 turn/interrupt。 |",
        "| 发送失败 | 同一隔离 Runtime 先经 `load()` 回放只读发现（health、capabilities、sessions、thread/list、model/list、account "
            "只读回复），用录制目录中的 model1。Runtime.submit 是 send 的既有提交路径；缺失附件在 dispatch 内、ensureThread 之前失败。严格 allowlist "
            "禁止推理／业务写请求，不调用 start/SSE、不连网络或 Core。原始回执为附件无法恢复，错误由 Runtime.report 写入。 |",
     "| Core 错误事件 | 录制 error 事件经 Store.apply／EventReducer 写 operationError 和 notice；真实 phase 允许随该事件改变，Context 与资料不变。 |",
        "| 外观保存失败 | 原 LocalPresentationState.setIdentity＋内存 storage.writeError；现有 setter 负责回滚；工具复现 "
            "OrganicWindow.onIdentityChanged 的 catch 原文和 store.changed，无 Window/App。 |", "",
        "前两次诊断只暴露发送夹具准入前提不成立：未做发现／恢复偏好指向移除模型。没有放宽断言，也未为夹具改产品逻辑；最终用真实只读发现和原始失败回执闭合证据。", "",
        "### 5. 七个负例与套件结果", "", "每个负例只改私有检查包，均编译 exit 0、运行 exit 1，且只命中预定类别。", "",
        "| 负例 | 检查数 | 失败数 | 唯一类别 |", "| --- | ---: | ---: | --- |"]
    for row in config["negatives"]:
        lines.append(f"| `{row['name']}` | {row['checks']} | {row['failures']} | `{row['category']}` |")
    lines += ["", "`operation-as-read` 只把 availability 的未读限定删除，恢复 operationError 一出现就读取失败；`read-failure-swallowed` 把显式 "
        "historyError 返回值改成 unloaded。恢复产品源码后 D 2070／0，32 张恢复帧重新生成。", "",
        "| 套件 | 检查／失败 |", "| --- | ---: |", "| 主 target release | 编译 exit 0 |"]
    for row in config["suites"]:
        lines.append(f"| {row['name']} | {row['checks']}／0 |")
    lines += ["", "### 6. #218 成本（原口径、2× 逐个样本）", "",
        "未改 b/c/d-cost、PanelsBCostMain 的计时或就绪定义。每条路径每个 scale 冷首开 5 个全新进程，热重开 15 次；冷关 5＋热关 15 次。1× 只记不判；2× "
            "每个样本都判，原样本／p50／p90／max 保存在各 `summary.json` 和 `records`，本表列 max。", "",
        "| 路径 | 倍率 | 冷贴图 ms | 冷 HD ms | 热 HD ms | 冷关释放 ms | 热关释放 ms | HD 峰值 B |",
            "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"]
    for title, path in [("原 mock", "regression/b-cost"), ("C live", "c-cost"), ("D 动作宿主", "d-cost")]:
        data = read("r5e-final/" + path + "/summary.json")
        for scale in [1, 2]:
            values = [data["costs"][f"{scale}x/{key}"]["max_ms"] for key in ["cold/firstTexture", "cold/firstHD",
                    "warm/firstHD", "cold-close/released", "warm-close/released"]]
            peak = max(row["peakHD"] for row in data["records"] if row["scale"] == scale)
            lines.append("| " + title + " | " + str(scale) + "× | " + " | ".join(
                    f"{value:.3f}" for value in values) + f" | {peak} |")
    lines += ["| 2× 上限 | 逐样本 | 120 | 200 | 150 | 20 | 20 | 16777216 |", "",
        "三条成本门各 140／0，无 #218 停止项；16 MiB 实际账本上限未改。原样本位于 MBA 成本任务对应的 `out/m1140-{b,c,d}-cost/.../summary.json`。"
            "共享路径 0 行，#144 不扩大跑 Column Work；源码调用搜索确认 Sources 的 Panels 之外无调用新模块，默认产品入口未变。主线程 HD 解码／上传与 8.3 ms "
            "实窗停顿门仍按既定安排留步骤 E，本轮不做、不判。", "",
        "### 7. MBA 任务表", "",
            "所有任务先经主树 mac.ps1 ship，再使用 build/heavy/detach/wait-min 480；严格串行。每批实际运行不超过 20 分钟，批次合计估时小于一小时；队列等待单列。"
            "交前空间均 ≥20 GiB，无 clean／绕过。", "",
        "| 任务 | 用途 | 交前 GiB | 排队 s | 运行 s | exit |", "| --- | --- | ---: | ---: | ---: | ---: |"]
    for row in config["jobs"]:
        assert row["freeGiB"] is not None
        lines.append(
f"| `{row['id']}` | {row['purpose']} | {row['freeGiB']} | {row['queueSeconds']} | {row['runSeconds']} | {row['exit']} |"
        )
    lines += ["", "### 8. 帧与回执路径", "",
        "共 58 张最终帧：D 恢复 32（包含 failure-0…5 和四种错误 Overview 2×），C 真数据／缺值 26（包含 context-used-only、phase-unknown 的 "
            "1×／2×）。每张原生尺寸已核；缩略检查确认 Context 和右轨保留、错误独立可见。真实玻璃继续交 Claude。MBA 相对路径逐张如下：", ""]
    lines += ["- `" + path + "`" for path in config["framePaths"]]
    lines += ["", "本地回执核验清单：`tools/m1140/evidence/r5e-results.json`；本地范围／编码审计：`r5e-audit.json`。验证批次的 positive、七负例、"
        "restored 回执均带同一套 19 个产品指纹；C、三条成本、B、overlay 与批次总回执逐项相等。A 回执自带 18 个 Panels 指纹，release／接线／A "
        "的无指纹外层回执由同批不可变源码的 19 指纹总回执关联。", "",
        "### 9. 全部产品 SHA-256 与边界", "", "| 文件 | SHA-256 |", "| --- | --- |"]
    for name, value in audit["sourceHashes"].items(): lines.append(f"| `{name}` | `{value}` |")
    lines += ["", "另核未改的 BodyResources：`" +
        baseline["shared"]["Sources/OrganicShell/BodyPresentation/BodyResources.swift"] + "`。", "",
        "本轮没有新增动作、正式入口或产品调用。此前未接通的 Rename、Model、Compact、Archive／Undo、资料 Open／Copy 及 Library Core 只读预览接口维持原缺口，"
            "不在本轮处理。Context 位置仍照默认球内，口味与实窗检查留步骤 E。没有触发共享文件／16 MiB／成本停止条件。", ""]
    text = "\n".join(lines)
    assert "??" not in text and "\r" not in text
    report.write_bytes(prefix + text.encode("utf-8"))
    raw = report.read_bytes(); decoded = raw.decode("utf-8", errors="strict")
    assert raw[:len(prefix)] == prefix and b"\r" not in raw and not raw.startswith(b"\xef\xbb\xbf")
    assert decoded.count("## 第五轮修正（操作错误与读取失败）") == 1 and "??" not in raw[len(prefix):].decode("utf-8")
    print(json.dumps(dict(reportBytes=len(raw), prefixBytes=len(prefix), appendedLines=text.count("\n"),
            UTF8NoBOMLF=True), ensure_ascii=False))


if __name__ == "__main__":
    main()
