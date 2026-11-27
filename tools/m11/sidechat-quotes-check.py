"""Pinned offline sidechat quotation gate. Real attachments, no upstream turn starts."""
import asyncio
import json
from pathlib import Path
import runpy
import sys

fixtures = runpy.run_path(str(Path(__file__).with_name("sidechat-core-check.py")))
from transport import RpcFailure, StdioTransport
http, scan = (fixtures[name] for name in ("http", "scan"))
close_owned, marked_boundary = (fixtures[name] for name in ("close_owned", "marked_boundary"))
new_core, verified_cli = (fixtures[name] for name in ("new_core", "verified_cli"))
QUOTE, RECEIPT = "organicSidechatQuote", "organicSidechatDelivery"
SUMMARY = "P2_ALLOWED_QUOTE_734B"
PRIVATE = ("P2_PRIVATE_QUESTION", "P2_PRIVATE_FULL_ANSWER", "P2_PRIVATE_COMMENTARY", "p2-private-answer-id")


async def run(root, cli, mode, evidence):
    home = root / "codex-home"
    marker = fixtures["MARKS"][2] + "_" + fixtures["token_hex"](12)
    home.mkdir(parents=True)
    (home / "config.toml").write_bytes((
        'model_provider="offline"\nmodel="mock-model"\ncheck_for_update_on_startup=false\n'
        '[model_providers.offline]\nname="Offline"\nbase_url="http://127.0.0.1:9/v1"\nwire_api="responses"\n'
    ).encode("utf-8"))
    pids, frames, children = [], [], []
    evidence.update(pids=pids, frames=frames, children=children, boundaryMarker=marker)
    original_send = StdioTransport.send
    lost, automation = False, False
    starts = 0

    async def stdio(transport, raw):
        message = json.loads(raw)
        assert message.get("method") not in ("turn/start", "turn/steer", "account/login/start")
        await original_send(transport, marked_boundary(message, raw, marker))

    async def start():
        nonlocal session
        session = new_core(root, cli)
        await session.start()
        pids.append(session.app_transport.process.pid)
        print(f"{mode} owned App Server PID {pids[-1]}", flush=True)
        assert session.sidechat_quotes.enabled and not session.sidechats.reason, session.sidechats.reason
        request = session.app.request

        async def call(method, params=None, *, timeout=30):
            nonlocal lost, starts
            if method == "thread/goal/get" and automation:
                return {"goal": {"status": "active"}}
            if method in ("turn/start", "turn/steer"):
                frames.append({"method": method, "params": params})
                if method == "turn/steer":
                    return {"turnId": "busy-parent"}
                starts += 1
                turn = {"id": f"parent-turn-{starts}", "status": "inProgress"}
                if starts == 2:
                    await note(session, params["threadId"], "turn/completed", turn=dict(turn, status="completed"))
                return {"turn": turn}
            result = await request(method, params, timeout=timeout)
            if lost and method == "thread/attachment/add" and params.get("attachmentType") == QUOTE:
                lost = False
                raise RpcFailure(-32002, "Fixture dropped write receipt", sent=True)
            return result

        session.app.request = call

    async def rpc(server, method, **params):
        return await http(server, "/rpc", {"method": method, "params": params})

    async def listing(server, parent, kind):
        reply = await rpc(server, "thread/attachment/list", threadId=parent)
        return [row for row in reply["result"]["data"] if row["attachmentType"] == kind]

    async def note(session, thread, method, **params):
        await session.notification({"method": method, "params": {"threadId": thread, **params}})

    def disk(*, require_quote):
        rows = scan(root, (*PRIVATE, marker, *children, SUMMARY), cli)
        hits = [r for r in rows if r["hits"]]
        assert hits or not require_quote
        assert all(r["hits"] == [SUMMARY] for r in hits), hits
        assert all(r["path"].startswith("codex-home/") and ".sqlite" in r["path"] for r in hits), hits
        return rows

    StdioTransport.send = stdio
    session = None
    try:
        await start()
        async with await asyncio.start_server(session.http, "127.0.0.1", 0) as server:
            parent = (await rpc(server, "thread/start", historyMode=mode))["result"]["thread"]["id"]
            other = (await rpc(server, "thread/start", historyMode=mode))["result"]["thread"]["id"]
            base = {"instanceId": session.instance_id, "parentThreadId": parent}
            lease = (await http(server, "/sidechat/open", base))["result"]
            child = lease["threadId"]
            children.append(child)
            send = dict(base, **lease)
            send["answerId"] = PRIVATE[3]
            route = "/sidechat/send-main"
            await note(session, child, "turn/started", turn={"id": "child-turn"})
            await note(session, child, "item/completed", turnId="child-turn",
                       item={"type": "userMessage", "id": "question", "content": [{"text": PRIVATE[0]}]})
            await note(session, child, "item/completed", turnId="child-turn",
                       item={"type": "agentMessage", "id": PRIVATE[3], "text": f"Summary: {SUMMARY}\n\n{PRIVATE[1]}",
                             "phase": "final_answer"})
            await note(session, child, "item/completed", turnId="child-turn",
                       item={"type": "agentMessage", "id": "comment", "text": PRIVATE[2], "phase": "commentary"})
            assert "error" in await http(server, route, send)
            await note(session, child, "turn/completed", turn={"id": "child-turn", "status": "completed"})
            assert "error" in await http(server, route, dict(send, parentThreadId=other))
            automation = True
            assert "error" in await http(server, route, send)
            automation = False
            await note(session, parent, "turn/started", turn={"id": "busy-parent", "status": "inProgress"})
            lost = True
            assert (await http(server, route, send))["error"]["requestSent"] is True
            quote = (await http(server, route, send))["result"]["quote"]
            evidence["quote"] = quote
            assert (await http(server, route, send))["result"]["quote"] == quote
            assert quote["payload"]["summary"] == SUMMARY and await listing(server, parent, QUOTE) == [quote]
            assert not await listing(server, other, QUOTE)
            payload = {"threadId": parent, "input": [{"type": "text", "text": "Normal input", "clientId": "stable"}],
                       "additionalContext": {"caller": {"kind": "untrusted", "value": "Normal context"}}}
            refused = await rpc(server, "turn/start", **payload)
            assert refused["error"]["code"] == -32012 and refused["error"]["requestSent"] is False and not frames
            steer = {"threadId": parent, "expectedTurnId": "busy-parent", "input": payload["input"]}
            await rpc(server, "turn/steer", **steer)
            assert frames[-1]["params"] == steer, "quote appeared on steer"
            await note(session, parent, "turn/completed", turn={"id": "busy-parent", "status": "completed"})
            turn = (await rpc(server, "turn/start", **payload))["result"]["turn"]
            context = frames[-1]["params"]["additionalContext"]
            key = "organic-sidechat/" + quote["identityKey"]
            assert frames[-1]["params"]["input"] == payload["input"], "quote modified composer input"
            assert context["caller"] == payload["additionalContext"]["caller"] and context[key]["kind"] == "untrusted"
            await note(session, parent, "turn/completed", turn=dict(turn, status="interrupted"))
            assert not await listing(server, parent, RECEIPT)
            await rpc(server, "turn/start", **payload)
            assert frames[-1]["params"]["additionalContext"] == context
            assert len(await listing(server, parent, RECEIPT)) == 1
            assert "result" in await rpc(server, "thread/archive", threadId=parent)
            assert "error" in await http(server, route, send)
        await close_owned(session, evidence, cli)
        evidence["firstExit"] = disk(require_quote=True)
        await start()
        async with await asyncio.start_server(session.http, "127.0.0.1", 0) as server:
            assert "result" in await rpc(server, "thread/unarchive", threadId=parent)
            assert await listing(server, parent, QUOTE) == [quote]
            assert "error" in await http(server, route, send)
            await rpc(server, "thread/resume", threadId=parent)
            await rpc(server, "turn/start", **payload)
            assert frames[-1]["params"] == payload, "a consumed quote was sent again"
            await note(session, parent, "turn/completed", turn={"id": f"parent-turn-{starts}", "status": "completed"})
    finally:
        await close_owned(session, evidence, cli)
        StdioTransport.send = original_send
        evidence["lastExit"] = disk(require_quote="quote" in evidence)


async def main(root, cli, output):
    evidence = {}
    try:
        cli = verified_cli(cli)
        for mode in ("legacy", "paginated"):
            await run(root / mode, cli, mode, evidence.setdefault(mode, {}))
    finally:
        output.write_bytes((json.dumps(evidence, indent=2) + "\n").encode("utf-8"))
    print("SIDECHAT_QUOTES: 2 cases, 0 findings, 0 model rounds")


if __name__ == "__main__":
    asyncio.run(main(*(Path(arg).resolve() for arg in sys.argv[1:])))
