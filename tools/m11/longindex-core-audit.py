#!/usr/bin/env python3
"""Offline M11.48 feasibility witnesses, never an inference implementation.

The default exit code is 2 while the four production guarantees are unproved.
--negative runs one required guarantee against the existing Core and must fail.
--self-test checks the witnesses, not the missing production capability.
"""
import argparse
import asyncio
import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "Runtime/Core"))
from core import Core
from event_log import EventLog
from transport import RpcClient

SYNTHETIC_ID = "m1148-synthetic-thread"
SYNTHETIC_TEXT = "M1148 synthetic summary; no user content."
GUARANTEES = ("no-tools", "no-rollout", "no-public-log", "no-history")


class FixtureTransport:
    """Only two metadata RPCs exist here; model turns cannot be sent."""

    def __init__(self):
        self.incoming = asyncio.Queue()
        self.sent = []
        self.closed = False

    async def send(self, raw):
        message = json.loads(raw)
        method = message["method"]
        if method not in ("thread/start", "thread/name/set"):
            raise AssertionError("Fixture refuses all other RPCs: " + method)
        self.sent.append(copy.deepcopy(message))
        if method == "thread/start":
            # A creation notification can arrive before its RPC acknowledgement.
            await self.incoming.put(json.dumps({
                "method": "thread/started",
                "params": {"thread": {"id": SYNTHETIC_ID}}
            }))
            result = {"thread": {"id": SYNTHETIC_ID}, "model": "gpt-6.1-terra"}
        else:
            result = {}
        await self.incoming.put(json.dumps({"id": message["id"], "result": result}))

    async def receive(self):
        return await self.incoming.get()

    async def close(self):
        self.closed = True
        await self.incoming.put(None)


def forbid_real_backend(*args, **kwargs):
    raise AssertionError("Real backend/process access is forbidden in this audit")


async def observe_existing_core(output_directory):
    """Exercise real Core methods with real EventLog and a queue-only transport."""
    with tempfile.TemporaryDirectory(prefix="fixture-", dir=output_directory) as temp:
        directory = Path(temp)
        # Avoid Core.__init__: it prepares persistent runtime/account state.
        instance = Core.__new__(Core)
        instance.args = SimpleNamespace(model="gpt-6.1-sol")
        instance.work = directory
        instance.sessions = {}
        instance.sessions_path = directory / "sessions.json"
        instance.changed = asyncio.Event()
        instance.log = EventLog(directory / "events.jsonl")
        instance.adapters = {}
        instance.dead = set()
        instance.approvals = {}
        instance.tool_context = {}
        dispatches = []

        async def fixture_tool(message):
            dispatches.append(message["params"]["tool"])
            return {"success": True, "contentItems": []}

        instance.register_adapter("fixture", "Synthetic namespace", [{
            "type": "function", "name": "syntheticTool", "description": "No side effects",
            "inputSchema": {"type": "object", "properties": {}}
        }], fixture_tool)
        transport = FixtureTransport()
        with patch("core.StdioTransport.start", side_effect=forbid_real_backend), \
             patch("core.Core.start", side_effect=forbid_real_backend), \
             patch("asyncio.create_subprocess_exec", side_effect=forbid_real_backend), \
             patch("asyncio.open_connection", side_effect=forbid_real_backend), \
             patch("asyncio.open_unix_connection", side_effect=forbid_real_backend):
            instance.app = RpcClient(transport, notifications=instance.notification)
            try:
                await instance.rpc("thread/start", {
                    "model": "gpt-6.1-terra", "ephemeral": True,
                    "baseInstructions": "Summarize the supplied synthetic text."
                })
                await instance.server_request({
                    "id": "synthetic-tool-request", "method": "item/tool/call",
                    "params": {"namespace": "fixture", "tool": "syntheticTool",
                               "arguments": {}, "threadId": SYNTHETIC_ID,
                               "turnId": "synthetic-turn"}
                })
                await instance.notification({
                    "method": "item/agentMessage/delta",
                    "params": {"threadId": SYNTHETIC_ID, "turnId": "synthetic-turn",
                               "itemId": "synthetic-answer", "delta": SYNTHETIC_TEXT}
                })
                # Even explicitly empty dynamic tools cannot preserve ephemeral=true
                # through the existing Core wrapper. No builtin-tool claim is made.
                await instance.rpc("thread/start", {
                    "model": "gpt-6.1-terra", "ephemeral": True, "dynamicTools": []
                })
                events = list(instance.log.since(0))
                sessions = json.loads(instance.sessions_path.read_text())
                return {
                    "forwardedStarts": [m["params"] for m in transport.sent
                                        if m["method"] == "thread/start"],
                    "forwardedMethods": [m["method"] for m in transport.sent],
                    "toolDispatches": dispatches,
                    "publicEvents": events,
                    "publicLogContainsSyntheticSummary": SYNTHETIC_TEXT in instance.log.path.read_text(),
                    "publicSessions": list(sessions),
                    "fixtureInferenceRPCs": sum(m["method"] in {"turn/start", "turn/steer", "thread/sample"}
                                                for m in transport.sent),
                    "backendKind": "queue-only fake transport; real Core rpc/notification/persist"
                }
            finally:
                await instance.app.close()
                instance.log.close()


def inspect_protocol(directory):
    names = ("ThreadStartParams", "TurnStartParams", "ThreadSampleParams", "ThreadSampleResponse")
    result = {}
    for name in names:
        path = directory / "v2" / (name + ".json")
        raw = path.read_bytes()
        schema = json.loads(raw)
        result[name] = {
            "sha256": hashlib.sha256(raw).hexdigest(),
            "properties": sorted(schema.get("properties", {})),
            "required": schema.get("required", []),
        }
        if name == "ThreadSampleResponse":
            result[name]["textContract"] = schema["properties"]["text"]["description"]
    direct_controls = {"tools", "toolChoice", "tool_choice", "allowedTools", "allowed_tools"}
    result["directEmptyBuiltinToolControl"] = any(
        direct_controls.intersection(result[name]["properties"])
        for name in ("ThreadStartParams", "TurnStartParams"))
    result["limitation"] = (
        "No direct empty builtin-tool contract was found. The opaque config field "
        "does not prove unknown overrides are supported. This is not a proof that "
        "no upstream solution exists; actual builtin-tool assembly is unverified."
    )
    return result


def require_guarantee(name, observation):
    if name == "no-tools":
        assert not observation["toolDispatches"], "Existing Core dispatched a registered dynamic tool"
        assert not observation["forwardedStarts"][0]["dynamicTools"], "Dynamic tool catalog is nonempty"
    elif name == "no-rollout":
        assert all(p["ephemeral"] is True for p in observation["forwardedStarts"]), \
            "Existing Core forces ephemeral=false, including dynamicTools=[]"
    elif name == "no-public-log":
        assert not observation["publicEvents"], "Private-looking notifications entered the public event log"
    elif name == "no-history":
        assert not observation["publicSessions"], "Existing Core persisted a session and called thread/name/set"


def self_test(observation, protocol):
    assert observation["forwardedMethods"] == [
        "thread/start", "thread/name/set", "thread/start", "thread/name/set"]
    assert observation["forwardedStarts"][1]["dynamicTools"] == []
    assert observation["fixtureInferenceRPCs"] == 0
    assert observation["toolDispatches"] == ["syntheticTool"]
    assert observation["publicLogContainsSyntheticSummary"]
    assert observation["publicEvents"][0]["method"] == "thread/started"
    assert observation["publicSessions"] == [SYNTHETIC_ID]
    assert protocol["directEmptyBuiltinToolControl"] is False, "Protocol changed; repeat the capability review"
    assert "ephemeral" in protocol["ThreadStartParams"]["properties"]
    assert "model" not in protocol["ThreadSampleParams"]["properties"]
    assert "expectedTurnId" in protocol["ThreadSampleParams"]["required"]
    assert "tool call" in protocol["ThreadSampleResponse"]["textContract"]
    for name in GUARANTEES:
        try:
            require_guarantee(name, observation)
        except AssertionError:
            continue
        raise AssertionError("A baseline negative stopped failing: " + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--protocol-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--negative", choices=GUARANTEES)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    observation = asyncio.run(observe_existing_core(args.output_dir))
    protocol = inspect_protocol(args.protocol_dir)
    report = {
        "status": "BLOCKED", "productionCapabilityProven": False,
        "reason": "No verified empty builtin-tool assembly contract for standalone Terra inference",
        "protocol": protocol, "baselineObservation": observation,
        "scope": "Metadata-only synthetic fixture; no official server, model, account, or user thread access"
    }
    (args.output_dir / "audit.json").write_text(json.dumps(report, indent=2) + "\n")
    if args.negative:
        require_guarantee(args.negative, observation)
        raise AssertionError("Baseline negative unexpectedly passed")
    if args.self_test:
        self_test(observation, protocol)
        print("PASS: offline witness checks; all four baseline requirements still fail. Capability remains BLOCKED.")
        return 0
    print("BLOCKED: standalone no-tools inference is unproved; baseline violations recorded in audit.json")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
