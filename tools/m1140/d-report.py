"""Write the D handoff from verified local MBA receipts, preserving every preceding report byte."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE = ROOT / "tools/m1140/evidence"


def main():
    config = json.loads((EVIDENCE / "d-results.json").read_text(encoding="utf-8"))
    audit = json.loads((EVIDENCE / "d-final-audit.json").read_text(encoding="utf-8"))
    hashes = audit["sourceHashes"]
    for filename in config["verifiedReceipts"]:
        receipt = json.loads((EVIDENCE / filename).read_text(encoding="utf-8"))
        if "sourceHashes" in receipt:
            for path, value in receipt["sourceHashes"].items():
                assert hashes[path] == value, (filename, path)
        assert receipt.get("sourceUnchanged", True), filename
    def load(name): return json.loads((EVIDENCE / config[name]).read_text(encoding="utf-8"))
    positive, restored = load("positive"), load("restored")
    assert positive["runExit"] == restored["runExit"] == 0 and not positive["failures"] and not restored["failures"]
    negatives = [json.loads((EVIDENCE / filename).read_text(encoding="utf-8")) for filename in config["negatives"]]
    assert len(negatives) == 5
    assert all(r["buildExit"] == 0 and r["runExit"] == 1 and r["validNegative"] and r["onlyExpectedCategory"]
        for r in negatives)
    for row in config["suites"]:
        assert row["failures"] == 0, row
    source_rows, tool_rows = [], []
    changed = subprocess.check_output(["git", "diff", "--numstat"], cwd=ROOT, text=True).splitlines()
    for row in changed:
        add, remove, path = row.split("\t")
        if path.startswith("Sources/OrganicShell/Panels/"):
            source_rows.append(
f"| `{path.rsplit('/', 1)[-1]}` | +{add}/−{remove}；现 {len((ROOT / path).read_text(encoding='utf-8').splitlines())} 行 |")
    for path in subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT,
        text=True).splitlines():
        rows = source_rows if path.startswith("Sources/OrganicShell/Panels/") else tool_rows
        if path.startswith(("Sources/OrganicShell/Panels/", "tools/m1140/")) and (ROOT / path).is_file():
            rows.append(f"| `{path}` | 新建 {len((ROOT / path).read_text(encoding='utf-8').splitlines())} 行 |")
    negative_rows = "\n".join(
        f"| `{r['case']}` | {r['checks']} | {len(r['failures'])} | `{r['expectedCategory']}` | 0 / 1 |"
        for r in negatives)
    suite_rows = "\n".join(f"| {r['name']} | {r['checks']} / {r['failures']} | `{r['path']}` |"
        for r in config["suites"])
    job_rows = "\n".join(
        f"| `{r['id']}` | {r['purpose']} | {r['freeGiB']} | {r['queueSeconds']} | {r['runSeconds']} | {r['exit']} |"
        for r in config["jobs"])
    costs = []
    for label, filename in config["costSummaries"].items():
        summary = json.loads((EVIDENCE / filename).read_text(encoding="utf-8"))
        selected = summary["costs"]
        metrics = ["2x/cold/firstTexture", "2x/cold/firstHD", "2x/warm/firstHD", "2x/cold-close/released",
            "2x/warm-close/released"]
        for metric in metrics:
            row = selected[metric]; costs.append(f"| {label} | {metric} | {row['n']} | {row['max_ms']:.3f} |")
        peak = max(r["peakHD"] for r in summary["records"] if r["scale"] == 2)
        costs.append(f"| {label} | 2× HD 峰值（B） | 5 个新进程 | {peak} |")
    cost_rows = "\n".join(costs)
    frame_rows = "\n".join("- `" + path + "`" for path in config["framePaths"])
    fingerprint_rows = "\n".join(f"| `{path}` | `{value}` |" for path, value in sorted(hashes.items()))
    full_maps = sum(len(json.loads((EVIDENCE / name).read_text(encoding="utf-8")).get("sourceHashes",
            {})) == len(hashes) for name in config["verifiedReceipts"])
    section = (
        f'''

## 第五轮（步骤 D）

### D.1 范围、在飞接口与文件

基点 `e5c7202`。只在 Panels、tools/m1140 和本文追加；共享文件改动 0 行，git 只读，没有产品入口、真实对话写入、模型请求、Core 网络请求或实窗。正式入口仍留步骤 E，Context 继续默认放球内。

'''
        f'''开写前只读核对：甲线 m1138-attach 的 HEAD `620f269`，WIP 在拖拽、Dock 和 transition，没有改 Runtime、Conversation、'''
        f'''身份持久化及动作写口；丙线 m1146 的 HEAD `f33da49`，WIP 涉及 OrganicWindow、HeaderIsland、AutoScene 等 Browser 宿主。'''
        f'''OrganicWindow 是同文件不同段：Browser 生命周期和 mode/command/key/close 挂接，没有改本轮读取的 rename/identity/compact '''
        f'''注入段。没有合入或改动任何在飞文件。'''
        f'''

| 产品文件 | 行数 |
| --- | --- |
{chr(10).join(source_rows)}

'''
        f'''新 Commands 保存纯值能力、反馈、选色和收高几何；ActionOwner 只做提交资格、意图防重及回执转译，不实现业务写入；ActionHost 只挂专项宿主。Input 增加可选纯值 '''
        f'''commands；LiveHost 增加默认原样返回的 decorate 接点；View/Primitives 接反馈、实际布局框、原生输入意图；Pages/Projection 只改 '''
        f'''live 显示。A/B 的 mock 输入和业务呈现分支保留。'''
        f'''

| 专项工具 | 行数 |
| --- | --- |
{chr(10).join(tool_rows)}

### D.2 已接动作、测试数据与提交边界

'''
        f'''数据从 C 的 FunctionPanelCRecordedData 经真实 Store.apply/EventReducer 进入 Conversation；D 沿用 '''
        f'''CoreControllerFixture 的内存 transport，记录 completed 历史和 whole-Fork 响应，child-active 也经 turn/started '''
        f'''事件进入 reducer。使用真实 LiveConversationRuntime，注入隔离 store、内存 LocalPresentationState/attachment '''
        f'''storage；**不调用 start/load**。transport 只允许 thread/read、thread/fork、turn/interrupt、health，'''
        f'''其他请求直接触发检查失败。连接检查读测试 Runtime 的公开 isConnected。能力由专项 owner 的可撤销输入提供，不宣称真实 Core 已报告全部能力。'''
        f'''

| 动作 | 复用写口及成功证据 | 失败证据 |
| --- | --- | --- |
'''
        f'''| 身份 body | LocalPresentationState.setIdentity，校验/保存/回滚全部留在原函数；检查 store 的 symbol 和一次内存持久化 | 注入 '''
        f'''storage 原错误；symbol/tint 恢复，选中草稿仍在 |'''
        f'''
| 选色 | 同一个 setIdentity，仅传新的 tint，symbol 取提交时真实值；候选来自现有 BodyTintCatalogue.legacy | 同一保存失败路径，已存 tint 恢复，选色输入保留 |
'''
        f'''| whole Fork | runtime.forkWhole → OrbWholeForkRequest；thread/fork 恰一次、threadId 正确、没有 '''
        f'''beforeTurnId；源只读，store 仅增加验证过的 child | thread/fork 拒绝后无占位对话、store 不增加；显示原错误 |'''
        f'''
'''
        f'''| Stop | runtime.interrupt 的 CoreSubmissionReceipt；恰一次 turn/interrupt，父 thread/turn 正确，'''
        f'''store.stopping 真 | 明确 409 拒绝后原 Runtime 回滚 stopping，面板显示 receipt 原错误；accepted 只写 Stop accepted，'''
        f'''不冒充 turn 已完成 |'''
        f'''
| child Stop | 同一 interrupt，目标是打开时捕获并再次核对的实际 child Conversation | child 回滚；父对话 stopping、next、draft 不被当作 child 修改 |
'''
        f'''| child Open | SheetSubAgentWindows.present；注入原有 SheetWindowFactory 的纯离屏 handle，检查 openIDs 和真实 '''
        f'''history view | 已占用同 ID 的其他 parent 使原函数返回 false；反馈可见，不开 NSWindow |'''
        f'''

'''
        f'''所有成功/失败均检查 store 与 transport/持久化结果，不以 UI 回调被调用作成功依据。远端 Fork 还会读取源历史及 health，这些读请求与恰一次的写 RPC 分开统计。'''
        f'''选色保持画板九个珠位、原直径和 pitch；现有 13 个真实 legacy 候选通过滚轮/方向键访问其余四个，不借用 mock 色名或改已有 palette。'''
        f'''

'''
        f'''提交时重新核对 parent 对象、store 身份、backendThreadID、child 对象及归属，再读当前连接和能力；Fork 的 actor 任务开始调用 Runtime '''
        f'''前再次执行同一核对。替换/关闭/ID 变化、断线、能力撤回均零请求、store 不变，反馈绘制在 y=672、高 56 pt 的可关闭浮层中，完整留在既有 #213 覆盖范围内。关闭消息只清 '''
        f'''UI 反馈，不写 store、不发 RPC。新标题、next/draft、选中项和滚动位置保留。'''
        f'''

'''
        f'''防重按显式意图：原生首击/新按键/独立 AX 指令创建新意图；双击第二击、按键 repeat 和同意图重复投递不重复写入。成功和失败回执都保留在同一意图内，快速失败不会因第二击重发；'''
        f'''明确的新意图仍可重试或再次 Fork。新增检查也覆盖 Fork 从点击回调到 actor 启动之间的三类资格变化。'''
        f'''

### D.3 未接动作：需要的共享接口

以下均无 live 按钮、入口或成功提示。行数是最小接口改动估计，不含检查；本轮没有实施。

| 动作 | 卡点、不能绕开的原因 | 最少共享改动估计 |
| --- | --- | --- |
'''
        f'''| Rename／Customize 名字 | Core/LiveConversationRuntime.swift:rename 是内部 Task 的 void 写口；'''
        f'''AutoScenePresentation.wireIsland/onRename、OrganicWindow 的注入也没有成功回执。观察 operationError 不能证明异步保存成功，'''
        f'''复制 RPC 则违反复用要求 | Runtime/协议/Mock 与 App/Scene 注入约 18–26 行，增加 Result 完成口 |'''
        f'''
'''
        f'''| Model | AutoScenePresentation.bindOverlays 只持有 full composer 的 OverlayComposerBinding；其 '''
        f'''presentModelPicker、NativeComposer.setSettings 写实际 next，专项面板没有这个带目标的 composer owner。不能另做模型业务或直接写 '''
        f'''next | bindOverlays/宿主注入带目标回调约 12–20 行 |'''
        f'''
'''
        f'''| Compact | LiveConversationRuntime.compactNow 内部 Task 不返回回执，OrganicWindow.onCompact 是 void；'''
        f'''不能把调用过当压缩成功 | Runtime/协议/Mock/App 约 8–12 行，明确 requested 回执而非伪造压缩完成 |'''
        f'''
'''
        f'''| Archive／Undo | LiveConversationRuntime.setArchived 同样无异步完成口；AutoSceneOrbActions.archiveOrb/undo'''
        f'''OrbArchive 还拥有成员/布局/Undo 事务，不能在 Panels 复制或只改 archived | Result 写口及 Scene 归档事务注入约 20–30 行 |'''
        f'''
'''
        f'''| Library／Outputs Open、Copy，Files Open | CoreArtifactsController.openOriginal 依赖 selectedID、'''
        f'''selected 路径和本地验证，没有独立目标接口；NativeTranscriptRow.copyMessage 依赖真实已挂载 row 的 item.text，不能构造假 row 冒充 '''
        f'''artifact/diff。不能扰动 Tools 当前选中，也不能把打开回调当成功 | Core 只读目标/内容与结果接口、App 目标注入合计约 40–65 行；Files 单独目标回调约 '''
        f'''12–18 行 |'''
        f'''

'''
        f'''Library 真缩略图所需的 Core 独立只读预览接口仍是单独缺口，本轮没有做。Background 没有通用真实 job Stop/Restart 能力，不把 conversation '''
        f'''Stop 冒充单项命令控制。通知策略、Pin to Dock、Export 继续仅 mock。Rename 没有接 live，因此其 Enter/blur 单次 RPC 验收留到获得 '''
        f'''Result 写口后；A 的纯编辑 Enter/blur/Esc 检查保留。本轮通过现有纯视图编辑状态探针核对新标题保留，不把它冒充已接通 Rename。'''
        f'''

### D.4 两处字面缺口与 C 断言

'''
        f'''live 的无来源 compactHistory 整行省略；有真实 reported compaction events 才出现。Model 下的 Not provided、Context 的 '''
        f'''Limit not provided 保留。删掉 Notifications not provided · Dock pin not provided · Export not '''
        f'''provided，Projection 的 live 语义列表也不再携带这行。'''
        f'''

'''
        f'''live Overview 最后一个 State/Model 值框底为 y=139；无历史时动作行直接在 y=149，按钮间距 11 pt，末行下方 16 pt；有动作时卡片高 193 pt，'''
        f'''没动作时 155 pt。检查读实际绘制 label 框、按钮框及 glass 框，确认删行后没有空洞。mock 仍走原 252 pt 几何。'''
        f'''

**C 原断言改动 0 项**：PanelsCCheckMain.swift、C 的五个负例、A/B/overlay 与既有成本工具均未改。没有需要逐条替换的原/新 C 断言；677 项按原样重跑。D 增加显示和几何断言，不削弱原检查。

### D.5 正例、负例和成本

| 套件 | 检查/失败 | MBA 输出 |
| --- | --- | --- |
{suite_rows}

'''
        f'''D 正例 {positive['checks']}/0，恢复正例 {restored['checks']}/0；输出帧数分别 {positive['frames']}、'''
        f'''{restored['frames']}。五个负例均私有包内变异，产品源不变；全部编过、二进制 exit 1，失败只在预定类别。'''
        f'''

按每套最终正例各计一次，共 {sum(row['checks'] for row in config['suites'])}/0；不把恢复复跑、诊断版或负例预期失败计入此总数。release 另以编译 exit 0 验收。

| 负例 | 检查数 | 失败数 | 唯一类别 | build/run exit |
| --- | --- | --- | --- | --- |
{negative_rows}

'''
        f'''下列均按 2× 每个样本判 max，1× 照原工具留原样本但不判。门保持首贴图 120 ms、冷 HD 200 ms、热 HD 150 ms、关闭释放 20 ms、HD 16 MiB。D '''
        f'''成本是额外的动作宿主路径，直接沿用 PanelsBCostMain 的时钟、就绪和样本计划，只替换构造宿主和实际 phase serial 比较；原 B/C 工具没动。'''
        f'''

| 路径 | 2× 指标 | n | max（时间 ms，峰值 B） |
| --- | --- | --- | --- |
{cost_rows}

'''
        f'''原样本、p50/p90/max 和分段首帧均在各成本任务 summary.json、s1-*.json、s2-*.json。HD/图片/phase 释放零状态随每个关闭样本检查；没有提高或绕开 '''
        f'''BodyResources 实际账本。#218 的 HD 解码/上传线程与动画主线程 8.3 ms 实窗测量仍留步骤 E，本轮不测不判。'''
        f'''

### D.6 MBA 任务与帧

'''
        f'''任务全部经主树 tools/mac/mac.ps1、item m1140，先 ship，run --prio build --heavy --detach --wait-min 480，逐个 '''
        f'''wait；每个任务内部限 1,150 秒。每次提交前检查空间；未绕过测量保护、队列或空间门。任务表包括探查/修正任务，最终回执另按源码指纹核对。'''
        f'''

| 任务 | 内容 | 提交前 GiB | 排队秒 | 运行秒 | exit |
| --- | --- | --- | --- | --- | --- |
{job_rows}

帧均是离屏 PNG，没有开实窗。八场景 1×/2×、拒绝反馈及失败回滚代表帧位于：

{frame_rows}

{config.get('frameNotes', '')}

### D.7 全部产品指纹与 E 接点

'''
        f'''最终采用 {len(config['verifiedReceipts'])} 份回执：其中 {full_maps} 份各含完整的 {len(hashes)} 个产品指纹并与本地逐项相等；A '''
        f'''的单独回执核对 18 个 Panels 文件；release/wiring/A 的三份执行单通过同任务 stage 的完整指纹关联。Stream 仍 32cce9ab…，'''
        f'''BodyResources 仍 9ecb7e63…，后者完整 SHA-256 为 '''
        f'''`{audit['shared']['Sources/OrganicShell/BodyPresentation/BodyResources.swift']}`。共享路径 0 行，'''
        f'''release 和接线检查通过；源码检索正常产品调用新代码为 0，因此不强制跑 #144 Column Work 等共享路径计时。'''
        f'''

| 产品文件 | SHA-256 |
| --- | --- |
{fingerprint_rows}

'''
        f'''E 只需由正式宿主注入同一 store/Runtime/LocalPresentationState、当前目标与连接/能力读取、既有共享 BodyResources 和 Sheet 窗口 '''
        f'''owner，再挂纯值 commands 与 actions。正式入口、#166、宿主撤场/焦点、真实资料 Open/Copy、Result 写口及 Model binding '''
        f'''仍需按既定顺序由总监安排；本轮没有接 Scene、HeaderIsland、Dock、Orb 或 App。没有获得回执的动作不伪装已完成。'''
        f'''

'''
        f'''本文前 {audit['reportPrefixBytes']} 字节逐字保留，前缀 SHA-256 `{audit['reportPrefixSHA256']}`。追加节通过 Python '''
        f'''strict UTF-8 读回、无 BOM、LF 和无连续问号乱码检查。'''
        f'''
'''
    )
    path = ROOT / "docs/reference/M11-40-PANELS-PLAN-SOL-261112.md"
    previous = path.read_bytes()[:audit["reportPrefixBytes"]]
    assert hashlib.sha256(previous).hexdigest() == audit["reportPrefixSHA256"]
    result = previous + section.encode("utf-8")
    assert b"\r" not in result and "??" not in section
    path.write_bytes(result)
    assert path.read_bytes() == result and path.read_text(encoding="utf-8", errors="strict").endswith(section)
    print(json.dumps({"bytes": len(result), "newLines": len(section.splitlines()), "products": len(hashes)},
            ensure_ascii=False))


if __name__ == "__main__":
    main()
