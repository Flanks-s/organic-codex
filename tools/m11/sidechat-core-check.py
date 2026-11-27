"""Offline M11.41 Core acceptance. Uses a fresh, disposable test root per invocation."""
import asyncio
from contextlib import suppress
import functools
from hashlib import sha256
import json
import os
from pathlib import Path
import re
from secrets import token_hex
import signal
import subprocess
import sys
from types import SimpleNamespace
from zipfile import ZipFile
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Runtime/Core"))
import core
from sidechat import BOUNDARY, DEVELOPER_INSTRUCTIONS
from transport import RpcClient, StdioTransport
MARKS = (
    "M1141_P1_C_QUESTION", "M1141_P1_C_ANSWER", "M1141_BOUNDARY",
    "M1141_P1_C_APPROVAL_REQUEST", "M1141_P1_C_APPROVAL_RESPONSE",
)
FAULTS = (
    "log-dir", "event-log", "durable", "diagnostic-capability", "feedback",
    "approval-event", "authorization", "permission-override",
)
APPROVAL_IDS = range(9001, 9010)

async def http(server, route, body=None):
    reader, writer = await asyncio.open_connection("127.0.0.1", server.sockets[0].getsockname()[1])
    raw = b"" if body is None else json.dumps(body).encode()
    writer.write(f"{'GET' if body is None else 'POST'} {route} HTTP/1.1\r\nContent-Length: {len(raw)}\r\n\r\n".encode())
    writer.write(raw)
    try:
        headers, data = (await asyncio.wait_for(reader.read(), 25)).split(b"\r\n\r\n", 1)
        if route.startswith("/sidechat/"):
            assert b"Cache-Control: no-store" in headers
        return json.loads(data)
    finally:
        writer.close()
        await writer.wait_closed()

if os.name == "nt":
    asyncio.create_subprocess_exec = functools.partial(
        asyncio.create_subprocess_exec, creationflags=subprocess.CREATE_NO_WINDOW)
else:
    asyncio.create_subprocess_exec = functools.partial(asyncio.create_subprocess_exec, start_new_session=True)

def verified_cli(entry):
    if sys.platform != "darwin":
        return entry.resolve(strict=True)
    pattern = r'(?m)^[ \t]*exec[ \t]+"\$bin_dir/([^"$`\\\n]+)"[ \t]+"\$@"[ \t]*$'
    targets = re.findall(pattern, entry.read_text(encoding="utf-8"))
    if len(targets) != 1 or Path(targets[0]).is_absolute():
        raise RuntimeError("Cannot parse bundled CLI exec line")
    cli = (entry.parent / targets[0]).resolve(strict=True)
    subprocess.run(["/usr/bin/codesign", "--verify", str(cli)], check=True, timeout=10)
    return cli

def new_core(root, cli, diagnostics=False):
    env = {k: v for k, v in os.environ.items() if k.upper() in {"PATH", "SYSTEMROOT", "WINDIR", "TMP", "TEMP"}}
    core.environment = lambda: dict(env, CODEX_HOME=str(root / "codex-home"), USERPROFILE=str(root))
    core.processes = lambda: {"rows": []}
    args = SimpleNamespace(work_root=str(root), data_dir=str(root / "core"), proxy=None, adapter=[], model="mock-model",
                           app_server_diagnostics=diagnostics)
    session = core.Core(args)
    core.paths.cli = cli
    return session

def scan(folder, markers, cli, *, aliases_only=False):
    files = []
    for path in sorted(folder.rglob("*")):
        if path.is_symlink():
            row = {"path": path.relative_to(folder).as_posix(), "isLink": True, "hits": ["unexpected-symlink"]}
            files.append(row)
            try:
                row["target"] = os.readlink(path)
                target = path.resolve(strict=True)
            except (OSError, RuntimeError):
                continue
            row["resolvedTarget"] = str(target)
            if target == cli and not target.is_relative_to(folder.resolve()):
                digest = sha256(cli.read_bytes()).hexdigest()
                row.update(cliSHA256=digest, targetSHA256=sha256(target.read_bytes()).hexdigest())
                if row["targetSHA256"] == row["cliSHA256"]:
                    row["hits"] = [s for s in markers if s in row["path"] or s in row["target"]]
            continue
        if aliases_only or not path.is_file():
            continue
        raw = path.read_bytes()
        hits = [s for s in markers if s.encode() in raw or s.encode("utf-16le") in raw or s in path.name]
        files.append({"path": path.relative_to(folder).as_posix(), "bytes": len(raw), "hits": hits})
        if path.suffix == ".zip":
            with ZipFile(path) as archive:
                for name in archive.namelist():
                    data = archive.read(name)
                    files.append({"path": name, "bytes": len(data), "hits": [s for s in markers if s.encode() in data]})
    return files
def group(pid):
    rows = subprocess.check_output(["/bin/ps", "-ax", "-o", "pid=,ppid=,pgid=,stat=,comm="], text=True, timeout=3)
    return [r.split(maxsplit=4) for r in rows.splitlines() if r.split()[2] == str(pid)]
async def close_owned(session, evidence, cli, *, disconnect=False):
    if session is None:
        return
    proc = session.app_transport.process if session.app_transport else None
    try:
        if proc and os.name == "posix":
            evidence.setdefault("processTrees", []).append({"appServerPID": proc.pid, "rows": group(proc.pid)})
        links = scan(session.data.parent / "codex-home", (), cli, aliases_only=True)
        evidence.setdefault("runtimeLinks", []).extend(links)
        assert not any(row["hits"] for row in links), links
        close = session.app_transport.close if disconnect else session.close
        await asyncio.wait_for(close(), 16)
    finally:
        if proc:
            with suppress(ProcessLookupError):
                if os.name == "posix":
                    os.killpg(proc.pid, signal.SIGKILL)
                elif proc.returncode is None:
                    proc.kill()
            evidence.setdefault("exits", []).append([proc.pid, await asyncio.wait_for(proc.wait(), 5)])

def marked_boundary(message, raw, marker):
    if message.get("method") != "thread/inject_items" or len(message["params"]["items"]) != 2:
        return raw
    first, second = json.loads(raw)["params"]["items"]
    assert DEVELOPER_INSTRUCTIONS in first["content"][0]["text"] and second["content"][0]["text"] == BOUNDARY
    return raw.replace(json.dumps(BOUNDARY, ensure_ascii=False), json.dumps(BOUNDARY + "\n" + marker), 1)


async def approval_probe(server, session, body, fault, evidence):
    tid = body["threadId"]
    base = {"threadId": tid, "turnId": "synthetic-turn", "reason": MARKS[3]}
    amendment = {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": ["fixture", MARKS[4]]}}
    frames = evidence["requests"]
    tasks = []

    async def ask(request_id, method, **extra):
        request = {"id": request_id, "method": method, "params": {**base, **extra}}
        task = asyncio.create_task(session.app.serve_request(request))
        tasks.append(task)
        await asyncio.sleep(0)
        return request, task

    async def card_for(request):
        result = await http(server, "/sidechat/events", body)
        cards = [e["params"] for e in result["result"]["events"] if e["method"] == "core/approvalRequested"]
        card = next(c for c in cards if c["request"]["id"] == request["id"])
        assert card["request"] == request
        assert card["threadId"] == tid and card["parentThreadId"] == body["parentThreadId"]
        assert card["source"] == "app-server" and card["turnId"] == base["turnId"]
        return card

    async def finish(request, task, card, response):
        reply = dict(body, approvalId=card["approvalId"], response=response)
        wrong = await http(server, "/sidechat/approval", dict(reply, lease="wrong-lease"))
        assert wrong["error"]["code"] == -32010
        assert (await http(server, "/sidechat/approval", reply))["result"]["responded"] == card["approvalId"]
        await asyncio.wait_for(task, 3)
        assert {"id": request["id"], "result": response} in frames
        assert (await http(server, "/sidechat/approval", reply))["error"]["code"] == -32003

    try:
        cmd, pending = await ask(9001, "item/commandExecution/requestApproval",
                                 command="echo " + MARKS[3], availableDecisions=["accept", amendment, "decline"])
        if fault == "authorization":
            private = session.sidechats.leases[tid]
            private.events[-1]["params"]["canRememberAuthorization"] = True
        card = await card_for(cmd)
        if card["canRememberAuthorization"]:
            evidence["findings"].append("remember-choice")
        else:
            assert card["canRememberAuthorization"] is False
        assert (await http(server, "/health"))["result"]["pendingApprovals"] == []
        auth = await http(server, "/authorizations", {"threadId": tid, "app": MARKS[3]})
        assert auth["error"]["code"] == -32602
        response = {"decision": amendment}
        await finish(cmd, pending, card, response)
        if fault == "approval-event":
            session.emit("core/approvalResponded", {**card, "response": response})
        if fault == "authorization":
            session.authorizations.add(tid, MARKS[3], response=response, origin=card["approvalId"])

        permit, pending = await ask(9002, "item/permissions/requestApproval", permissions={})
        await finish(permit, pending, await card_for(permit), {"permissions": {}, "scope": "session"})
        question, pending = await ask(9003, "item/tool/requestUserInput", questions=[])
        answer = {"answers": {"fixture": {"answers": [MARKS[4]]}}}
        await finish(question, pending, await card_for(question), answer)

        change, pending = await ask(9004, "item/fileChange/requestApproval", itemId="fixture-file")
        card = await card_for(change)
        resolved = {"threadId": tid, "requestId": change["id"]}
        await session.notification({"method": "serverRequest/resolved", "params": resolved})
        await asyncio.wait_for(pending, 3)
        assert any(f.get("id") == change["id"] and f.get("error", {}).get("code") == -32003 for f in frames)
        result = await http(server, "/sidechat/events", body)
        expired = [e for e in result["result"]["events"] if e["method"] == "core/approvalExpired"]
        assert expired[-1]["params"]["approvalId"] == card["approvalId"]
        await session.app.serve_request(change)
        assert frames[-1]["error"]["code"] == -32003

        tool = {"id": 9005, "method": "item/tool/call", "params": {**base, "tool": "fixture"}}
        await session.app.serve_request(tool)
        assert frames[-1]["error"]["code"] == -32010 and session.tool_context == {}
        _, closing = await ask(9006, "item/fileChange/requestApproval")
        assert (await http(server, "/sidechat/close", body))["result"]["closed"]
        await asyncio.wait_for(closing, 3)
        assert any(f.get("id") == 9006 and f.get("error", {}).get("code") == -32003 for f in frames)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def fake_provider(evidence):
    requests = evidence["mockProviderRequests"] = []

    async def respond(reader, writer):
        try:
            header = (await reader.readuntil(b"\r\n\r\n")).decode("latin1").splitlines()
            assert header[0].startswith("POST /v1/responses ")
            size = next(int(line.split(":", 1)[1]) for line in header if line.lower().startswith("content-length:"))
            body = json.loads(await reader.readexactly(size))
            tools = [tool.get("name") for tool in body.get("tools", [])]
            requests.append({
                "path": "/v1/responses", "model": body.get("model"), "toolChoice": body.get("tool_choice"),
                "inputKinds": [row.get("type") for row in body.get("input", [])], "tools": tools,
            })
            if not tools:
                writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
                return
            response = {"id": f"fixture-{len(requests)}"}
            if len(requests) == 1:
                assert "request_permissions" in tools
                args = {"reason": MARKS[3], "permissions": {"file_system": {"write": ["."]}}}
                item = {"type": "function_call", "call_id": "fixture-call", "name": "request_permissions",
                        "arguments": json.dumps(args)}
            else:
                assert len(requests) == 2
                assert any(row.get("call_id") == "fixture-call" for row in body["input"])
                item = {"type": "message", "id": "fixture-message", "role": "assistant",
                        "content": [{"type": "output_text", "text": MARKS[1]}]}
            usage = {"input_tokens": 0, "output_tokens": 0, "total_tokens": 0}
            frames = [
                {"type": "response.created", "response": response},
                {"type": "response.output_item.done", "item": item},
                {"type": "response.completed", "response": {**response, "usage": usage}},
            ]
            payload = "".join("data: " + json.dumps(frame) + "\n\n" for frame in frames).encode()
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n"
                         b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
            await writer.drain()
        finally:
            writer.close()
            await writer.wait_closed()

    return await asyncio.start_server(respond, "127.0.0.1", 0)


async def real_approval_probe(server, body, evidence):
    prompt = "Ask permission to write a fixture file. " + MARKS[0]
    result = await http(server, "/sidechat/send", dict(body, text=prompt))
    assert "turn" in result.get("result", {}), result
    cursor = 0

    async def wait_for(method):
        nonlocal cursor
        for _ in range(10):
            reply = await http(server, "/sidechat/events", dict(body, since=cursor))
            cursor = reply["result"]["cursor"]
            for event in reply["result"]["events"]:
                if event["method"] == method:
                    return event["params"]
                assert event["method"] != "turn/completed", event["params"]
        raise AssertionError("App Server did not emit " + method)

    card = await asyncio.wait_for(wait_for("core/approvalRequested"), 20)
    assert card["request"]["method"] == "item/permissions/requestApproval"
    assert card["request"]["params"]["reason"] == MARKS[3]
    assert card["canRememberAuthorization"] is False
    assert (await http(server, "/rpc", {"method": "config/batchWrite"}))["error"]["data"]["sidechats"][0]["running"]
    response = {"permissions": {}, "scope": "turn"}
    answer = await http(server, "/sidechat/approval", dict(body, approvalId=card["approvalId"], response=response))
    assert answer["result"]["responded"] == card["approvalId"]
    completed = await asyncio.wait_for(wait_for("turn/completed"), 20)
    assert completed["turn"]["status"] == "completed"
    assert len(evidence["mockProviderRequests"]) == 2
    sent = next(frame["params"] for frame in evidence["requests"] if frame.get("method") == "turn/start")
    assert {"approvalPolicy", "approvalsReviewer", "sandboxPolicy", "permissions"}.isdisjoint(sent)
    assert {"id": card["request"]["id"], "result": response} in evidence["requests"]
    evidence["realAppServerApproval"] = {"request": card["request"], "response": response}


async def run_case(root, cli, mode, fault, evidence):
    home = root / "codex-home"
    marker = MARKS[2] + "_" + token_hex(12)
    home.mkdir(parents=True)
    provider = await fake_provider(evidence) if mode == "paginated" and not fault else None
    port = provider.sockets[0].getsockname()[1] if provider else 9
    home.joinpath("config.toml").write_bytes((
        'model_provider="offline"\nmodel="mock-model"\ncheck_for_update_on_startup=false\n'
        'approval_policy="never"\nsandbox_mode="read-only"\n'
        '[features]\nrequest_permissions_tool=true\n[model_providers.offline]\n'
        f'name="Offline"\nbase_url="http://127.0.0.1:{port}/v1"\nwire_api="responses"\n'
        'request_max_retries=0\nstream_max_retries=0\n'
        '[mcp_servers.offline_fixture]\nurl="http://127.0.0.1:9/mcp"\n'
    ).encode("utf-8"))
    findings, children, receipts = [], [], []
    evidence.update(findings=findings, children=children, requests=receipts, boundaryMarker=marker)
    diagnostic = fault == "diagnostic-capability"
    original_options = core.app_server_options
    original_send = StdioTransport.send
    production_capabilities = core.capabilities
    async def watch(transport, raw):
        message = json.loads(raw)
        method = message.get("method", "")
        assert not method.startswith(("turn/steer", "account/login", "feedback/upload")), method
        assert method != "turn/start" or provider is not None, method
        if method == "config/mcpServer/reload":
            evidence["leasesAtRefresh"] = list(session.sidechats.leases)
        receipts.append(message)
        if message.get("id") not in APPROVAL_IDS:
            await original_send(transport, marked_boundary(message, raw, marker))
    def options(data, child_env, enabled):
        values, probe = original_options(data, child_env, enabled)
        if fault == "log-dir":
            values["log_dir"] = str(data / "logs")
        return values, probe
    def capabilities(instance):
        result = production_capabilities(instance)
        if fault == "diagnostic-capability":
            assert result["features"]["sidechat"]["available"] is False
            result["features"]["sidechat"]["available"] = True
        return result
    async def start():
        nonlocal session
        session = new_core(root, cli, diagnostic)
        await session.start()
        evidence.setdefault("pids", []).append(session.app_transport.process.pid)
        print(f"{mode}/{fault or 'positive'} owned App Server PID {evidence['pids'][-1]}", flush=True)
    session = None
    core.app_server_options = options
    core.capabilities = capabilities
    StdioTransport.send = watch
    try:
        await start()
        server = await asyncio.start_server(session.http, "127.0.0.1", 0)
        request = session.app.request
        delta = {"method": "item/agentMessage/delta", "params": {"delta": MARKS[1]}}
        async def intercepted(method, params=None, *, timeout=30):
            send = request
            if fault == "feedback" and method == "feedback/save":
                send = functools.partial(RpcClient.request, session.app)
            if fault == "permission-override" and method == "thread/fork":
                params = dict(params, approvalPolicy="never", sandbox="read-only")
            result = await send(method, params, timeout=timeout)
            if method == "thread/fork":
                evidence.setdefault("forkReplies", []).append({**result, "thread": dict(result["thread"])})
                children.append(result["thread"]["id"])
                delta["params"]["threadId"] = children[-1]
                if len(children) == 1:
                    await session.notification(delta)
                if fault == "durable":
                    result["thread"]["ephemeral"] = False
            return result
        session.app.request = intercepted
        async with server:
            rpc = lambda method, **params: http(server, "/rpc", {"method": method, "params": params})
            cap = (await http(server, "/capabilities"))["result"]["features"]["sidechat"]
            if cap["available"] == diagnostic:
                findings.append("diagnostic-capability" if diagnostic else "log-dir")
            parent = (await rpc("thread/start", historyMode=mode, ephemeral=True))["result"]["thread"]
            assert parent["path"] and not parent["ephemeral"] and parent["historyMode"] == mode
            parent_approval = "untrusted" if mode == "legacy" else "on-request"
            settings = await rpc("thread/settings/update", threadId=parent["id"], approvalPolicy=parent_approval,
                                 permissions=":workspace")
            assert "result" in settings, settings
            base = {"instanceId": session.instance_id, "parentThreadId": parent["id"]}
            opened = await http(server, "/sidechat/open", base)
            if diagnostic or fault in ("durable", "log-dir"):
                assert opened["error"]["code"] == -32010
                if fault == "durable":
                    findings.append("durable")
            elif cap["available"]:
                lease = opened["result"]
                fork = evidence["forkReplies"][-1]
                payload = next(f["params"] for f in receipts if f.get("method") == "thread/fork")
                forbidden = {"approvalPolicy", "approvalsReviewer", "sandbox", "permissions"}.intersection(payload)
                expected = fork["approvalPolicy"] == parent_approval and fork["sandbox"]["type"] == "workspaceWrite"
                if forbidden or not expected:
                    findings.append("permission-override")
                body = dict(base, **lease)
                tid = lease["threadId"]
                assert tid not in (await rpc("thread/loaded/list"))["result"]["data"]
                assert "error" in await rpc("thread/read", threadId=tid)
                for role, text in zip(("user", "assistant"), MARKS):
                    kind = "input_text" if role == "user" else "output_text"
                    item = {"type": "message", "role": role, "content": [{"type": kind, "text": text}]}
                    await request("thread/inject_items", {"threadId": tid, "items": [item]})
                await session.notification(delta)
                events = (await http(server, "/sidechat/events", body))["result"]
                assert events["events"][-1]["params"]["delta"] == MARKS[1]
                if provider:
                    await real_approval_probe(server, body, evidence)
                await approval_probe(server, session, body, fault, evidence)
                assert (await http(server, "/sidechat/close", body))["result"]["closed"]
                await session.notification(delta)
                if fault == "event-log":
                    session.emit(delta["method"], delta["params"])
                feedback = await rpc("feedback/save", threadId=parent["id"], includeLogs=True,
                                     savePath=str(root / "feedback.zip"), classification="bug")
                if feedback.get("error", {}).get("code") != -32010:
                    findings.append("feedback")
                for method in ("feedback/upload", "server/diagnostics"):
                    assert (await rpc(method))["error"]["code"] == -32010
                if not fault:
                    reopened = (await http(server, "/sidechat/open", base))["result"]
                    if mode == "legacy":
                        tid = reopened["threadId"]
                        change = {"instanceId": session.instance_id, "method": "config/mcpServer/reload"}
                        preview = (await http(server, "/sidechat/settings", change))["result"]
                        assert preview["sidechats"] == [{"threadId": tid, "hasContent": False, "running": False}]
                        await session.notification(delta)
                        refusal = await rpc(change["method"])
                        assert tid in session.sidechats.leases, "unconfirmed refresh closed a sidechat"
                        assert "leasesAtRefresh" not in evidence, "unconfirmed refresh reached App Server"
                        targets = refusal["error"]["data"]["sidechats"]
                        assert refusal["error"]["code"] == -32011 and refusal["error"]["requestSent"] is False
                        assert targets == [{"threadId": tid, "hasContent": True, "running": False}]
                        stale = await http(server, "/sidechat/settings", dict(change, confirm=preview["sidechats"]))
                        assert stale == {"result": {"sidechats": targets}} and "leasesAtRefresh" not in evidence
                        receipt = await http(server, "/sidechat/settings", dict(change, confirm=targets))
                        assert evidence["leasesAtRefresh"] == [], "confirmed refresh reached App Server before close"
                        assert "result" in receipt
                        evidence["refresh"] = {"empty": preview, "refused": refusal, "confirmed": receipt}
                    else:
                        await close_owned(session, evidence, cli, disconnect=True)
                        await session.app.reader_task
                    assert not session.sidechats.leases
                    assert not production_capabilities(session)["features"]["sidechat"]["available"]
            if diagnostic:
                assert "result" in await rpc("server/diagnostics")
                assert "result" in await rpc("feedback/save", savePath=str(root / "feedback.zip"), classification="bug")
        if not fault:
            await close_owned(session, evidence, cli)
            evidence["firstExit"] = scan(root, (*MARKS[:2], *MARKS[3:], marker, *children), cli)
            assert not any(row["hits"] for row in evidence["firstExit"])
            await start()
            assert parent["id"] in session.sessions
            assert not set(children).intersection(await session.sidechats.loaded())
            async with await asyncio.start_server(session.http, "127.0.0.1", 0) as restarted:
                assert (await http(restarted, "/sidechat/events", body))["error"]["code"] == -32602
    finally:
        StdioTransport.send = original_send
        core.capabilities = production_capabilities
        core.app_server_options = original_options
        await close_owned(session, evidence, cli)
        if provider:
            provider.close()
            await provider.wait_closed()
        evidence["files"] = scan(root, (*MARKS[:2], *MARKS[3:], marker, *children), cli)
        for row in evidence["files"]:
            if not row["hits"]:
                continue
            if row["path"].endswith("events.jsonl"):
                findings.append("approval-event" if MARKS[3] in row["hits"] else "event-log")
            elif row["path"].endswith("authorizations.json"):
                findings.append("authorization")
            elif row["path"].endswith("codex-logs.log"):
                findings.append("feedback-export")
            else:
                findings.append("unexpected-disk-hit")

async def main(root, cli, output):
    cases = [("legacy", None), ("paginated", None), *(("legacy", fault) for fault in FAULTS)]
    evidence = {}
    try:
        cli = verified_cli(cli)
        for mode, fault in cases:
            name = f"{mode}-{fault or 'positive'}"
            result = evidence[name] = {}
            await run_case(root / name, cli, mode, fault, result)
            expected = {fault} if fault else set()
            if fault == "feedback":
                expected.add("feedback-export")
            if fault == "authorization":
                expected.add("remember-choice")
            assert set(result["findings"]) == expected, (name, result["findings"])
    finally:
        output.write_bytes((json.dumps(evidence, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))
    print(f"SIDECHAT_CORE: {len(cases)} cases, 0 unexpected findings; 0 real model rounds")
if __name__ == "__main__":
    asyncio.run(main(*(Path(arg).resolve() for arg in sys.argv[1:])))
