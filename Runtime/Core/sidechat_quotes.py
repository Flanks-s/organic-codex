"""Parent-only persistence and next-turn delivery for explicitly exported sidechat quotes."""
import asyncio
from dataclasses import dataclass, field
from hashlib import sha256
import hmac
import re
from weakref import WeakValueDictionary

from sidechat import VERSION
from transport import RpcFailure

QUOTE = "organicSidechatQuote"
RECEIPT = "organicSidechatDelivery"
LIMIT = 8
SERIAL = {"thread/archive", "thread/unarchive", "thread/delete", "thread/goal/set",
          "thread/queue/add", "thread/queue/start"}


@dataclass
class Delivery:
    keys: list
    turn: str = None
    terminal: dict = field(default_factory=dict)


class SidechatQuotes:
    def __init__(self, core):
        self.core = core
        self.enabled = False
        self.locks = WeakValueDictionary()
        self.deliveries = {}
        self.tasks = set()

    def enable(self, init):
        self.enabled = init.get("userAgent", "").split(" ", 1)[0].rpartition("/")[2] == VERSION

    def lock(self, parent):
        return self.locks.setdefault(parent, asyncio.Lock())

    async def backend(self, method, parent, **params):
        return await self.core.app.request(method, {"threadId": parent, **params}, timeout=8)

    async def attachments(self, parent):
        quotes, consumed, cursor = [], set(), None
        while True:
            page = await self.backend("thread/attachment/list", parent, cursor=cursor, limit=100)
            for row in page["data"]:
                if row["attachmentType"] == QUOTE:
                    quotes.append(row)
                elif row["attachmentType"] == RECEIPT:
                    consumed.update(row["payload"]["keys"])
            cursor = page["nextCursor"]
            if cursor is None:
                return sorted(quotes, key=lambda row: row["payload"]["order"]), consumed

    async def add(self, parent, kind, key, payload):
        params = {"attachmentType": kind, "identityKey": key, "payload": payload}
        result = await self.backend("thread/attachment/add", parent, **params)
        attachment = result["attachment"]
        if attachment["payload"] != payload:
            raise RpcFailure(-32010, "Sidechat quote identity already has different content")
        return attachment

    async def check_automation(self, parent):
        checks = (
            ("thread/goal/get", {}, "goal", "goals feature is disabled"),
            ("thread/queue/list", {"limit": 1}, "data", "user message queue is unavailable"),
        )
        for method, params, field, disabled in checks:
            try:
                result = await self.backend(method, parent, **params)
            except RpcFailure as exc:
                if exc.code == -32600 and exc.message == disabled:
                    continue
                raise
            value = result[field]
            if value and (field != "goal" or value["status"] == "active"):
                raise RpcFailure(-32010, "Pause the parent goal or clear its Codex queue before sending a quote")

    @staticmethod
    def final_answer(side):
        turn = next((e["params"]["turn"] for e in reversed(side.events) if e["method"] == "turn/completed"), {})
        if turn.get("status") != "completed":
            return {}
        for event in reversed(side.events):
            params = event["params"]
            if event["method"] != "item/completed" or params.get("turnId") != turn["id"]:
                continue
            item = params["item"]
            if item["type"] == "agentMessage" and item.get("phase") in (None, "final_answer"):
                return item
        return {}

    @staticmethod
    def summary(text):
        conclusion = re.search(r"^\s*(?:summary|tl;dr|结论|摘要)\s*[:：]\s*(\S[^\r\n]*)", text, re.I | re.M)
        line = conclusion[1] if conclusion else next((s.strip() for s in text.splitlines() if s.strip()), "")
        return line if len(line) <= 240 else line[:239].rstrip() + "…"

    async def save(self, side, body):
        parent, answer_id = body.get("parentThreadId"), body.get("answerId")
        if parent != side.parent or not isinstance(answer_id, str) or not 0 < len(answer_id) <= 128:
            raise RpcFailure(-32602, "Expected the sidechat parent and completed answer ID")
        key = hmac.new(side.token.encode(), answer_id.encode(), sha256).hexdigest()
        async with self.lock(parent):
            leases = self.core.sidechats
            if leases.leases.get(side.tid) is not side or parent in leases.archived:
                raise RpcFailure(-32010, "Sidechat or parent is closed")
            quotes, consumed = await self.attachments(parent)
            if existing := next((q for q in quotes if q["identityKey"] == key), None):
                answer = self.final_answer(side)
                if answer.get("id") == answer_id and self.summary(answer["text"]) != existing["payload"]["summary"]:
                    raise RpcFailure(-32010, "Sidechat quote identity already has different content")
                return {"quote": existing}
            if sum(q["identityKey"] not in consumed for q in quotes) >= LIMIT:
                raise RpcFailure(-32010, "Start a new parent turn before sending more sidechat quotes")
            await self.check_automation(parent)
            turns = await self.backend("thread/turns/list", parent, limit=1)
            answer = self.final_answer(side)
            if leases.leases.get(side.tid) is not side or side.turn or side.lock.locked():
                raise RpcFailure(-32010, "Wait for the sidechat answer to finish")
            summary = self.summary(answer.get("text", ""))
            if answer.get("id") != answer_id or not summary or side.tid in summary:
                raise RpcFailure(-32010, "This is not the latest completed sidechat answer")
            anchor = turns["data"][0]["id"] if turns["data"] else None
            order = quotes[-1]["payload"]["order"] + 1 if quotes else 0
            source = hmac.new(side.token.encode(), b"display source", sha256).hexdigest()[:8]
            payload = {"summary": summary, "source": "Sidechat " + source, "anchorTurnId": anchor, "order": order}
            return {"quote": await self.add(parent, QUOTE, key, payload)}

    async def route(self, method, params, send):
        parent = params["threadId"]
        async with self.lock(parent):
            if method != "turn/start":
                if method == "thread/archive":
                    await self.flush(parent)
                result = await send(method, params)
                if method in ("thread/archive", "thread/delete"):
                    self.deliveries.pop(parent, None)
                    self.core.sidechats.retire_parent(parent)
                if method == "thread/unarchive":
                    self.core.sidechats.archived.discard(parent)
                return result
            await self.flush(parent)
            quotes, consumed = await self.attachments(parent)
            pending = [q for q in quotes if q["identityKey"] not in consumed]
            if not pending:
                return await send(method, params)
            await self.check_automation(parent)
            thread = (await self.backend("thread/read", parent, includeTurns=False))["thread"]
            session = self.core.sessions.get(parent, {})
            if thread["status"]["type"] not in ("idle", "notLoaded") or session.get("active"):
                raise RpcFailure(-32012, "Sidechat quotes are waiting for a new parent turn")
            context = dict(params.get("additionalContext") or {})
            keys = [row["identityKey"] for row in pending]
            for key, quote in zip(keys, pending):
                label = "organic-sidechat/" + key
                if label in context:
                    raise RpcFailure(-32602, "The sidechat quote context key is reserved")
                value = quote["payload"]
                context[label] = {"kind": "untrusted", "value": value["source"] + ": " + value["summary"]}
            delivery = Delivery(keys)
            self.deliveries[parent] = delivery
            try:
                result = await send(method, dict(params, additionalContext=context))
            except BaseException:
                self.deliveries.pop(parent, None)
                raise
            turn = result["turn"]
            delivery.turn = turn["id"]
            if turn["status"] != "inProgress":
                delivery.terminal.setdefault(delivery.turn, turn["status"])
            await self.flush(parent)
            return result

    def notification(self, method, parent, params):
        if method in ("thread/archived", "thread/deleted"):
            self.deliveries.pop(parent, None)
        if method != "turn/completed" or parent not in self.deliveries:
            return
        delivery = self.deliveries[parent]
        turn = params["turn"]
        if delivery.turn is None or turn["id"] == delivery.turn:
            delivery.terminal.setdefault(turn["id"], turn["status"])
            task = asyncio.create_task(self.settle(parent))
            self.tasks.add(task)
            task.add_done_callback(self.tasks.discard)

    def interrupted(self, parent, turn):
        delivery = self.deliveries.get(parent)
        if delivery and (delivery.turn is None or delivery.turn == turn):
            delivery.terminal.setdefault(turn, "interrupted")

    async def settle(self, parent):
        async with self.lock(parent):
            await self.flush(parent)

    async def flush(self, parent):
        delivery = self.deliveries.get(parent)
        if delivery is None or delivery.turn not in delivery.terminal:
            return
        self.deliveries.pop(parent)
        if delivery.terminal[delivery.turn] == "completed":
            try:
                await self.add(parent, RECEIPT, delivery.turn, {"keys": delivery.keys})
            except RpcFailure:
                pass  # The attachment remains pending unless the receipt actually reached storage.

    async def close(self):
        for task in self.tasks:
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        self.deliveries.clear()
