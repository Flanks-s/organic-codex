"""Owned stdio and documented Unix WebSocket app-server transports.

No listeners, account copying, automatic turn replay, or shared-process kills.
"""
from __future__ import annotations
import asyncio
import base64
import hashlib
import json
import os
import re
import secrets
import struct
import pathlib
import traceback
from typing import Any
from runtime_paths import paths

def diagnostic(where, error):
    with (paths.logs/'transport-diagnostics.jsonl').open('a') as f:
        f.write(json.dumps({'where':where,'error':str(error),'traceback':traceback.format_exc()})+'\n')

# Installed plugin/list returns more than 8 MiB; do not disconnect shared RPC
# while reading its legitimate catalog. This is a per-message bound, not a cache.
MAX_FRAME = 64 * 1024 * 1024


class RpcFailure(Exception):
    def __init__(self, code=-32000, message="官方后端请求失败", *, sent=False, data=None):
        super().__init__(message)
        self.code, self.message, self.sent, self.data = code, message, sent, data


def response_failure(error, *, public_message=False):
    """Keep general server errors opaque; opt in only after bridge auth.

    The owned product bridge projects errors through publicBridgeError before
    writing its socket. Never apply this opt-in to app-server or CUA MCP input.
    """
    if isinstance(error, dict):
        return RpcFailure(error.get('code',-32000),str(error.get('message',error)),data=error.get('data'))
    code = error.get("code") if isinstance(error, dict) else None
    if type(code) is not int or not -(2 ** 31) <= code < 2 ** 31:
        code = -32000
    message = "官方后端拒绝请求 (" + str(code) + ")"
    text = error.get("message") if isinstance(error, dict) else None
    if (public_message is True and isinstance(text, str) and 0 < len(text) <= 512
            and not any(ord(char) < 32 or 127 <= ord(char) < 160 for char in text)):
        message = text
    data = {"kind": "rpc-rejected"}
    supplied = error.get("data") if isinstance(error, dict) else None
    artifact_kinds = {"hostOffline", "notFound", "permissionDenied", "tooLarge", "unsupportedType",
                      "outsideRoot", "readFailed", "unsupportedHostVersion", "busy", "renderTerminated"}
    if (public_message is True and isinstance(supplied, dict) and supplied.get("kind") in artifact_kinds
            and isinstance(supplied.get("reason"), str) and re.fullmatch(r"[A-Za-z0-9-]{1,128}", supplied["reason"])):
        data = {"kind": supplied["kind"], "reason": supplied["reason"], "retryable": False}
    return RpcFailure(code, message, sent=False, data=data)


class StreamTransport:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer

    async def receive(self):
        try:
            data = await self.reader.readline()
        except (ValueError, asyncio.LimitOverrunError) as exc:
            raise RpcFailure(message="后端消息超过大小上限") from exc
        if not data:
            return None
        if len(data) > MAX_FRAME:
            raise RpcFailure(message="后端消息超过大小上限")
        return data.decode("utf-8")

    async def send(self, text):
        raw = text.encode("utf-8")
        if len(raw) > MAX_FRAME:
            raise RpcFailure(-32602, "请求超过大小上限")
        self.writer.write(raw + b"\n")
        await self.writer.drain()

    async def close(self):
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except (AttributeError, OSError, BrokenPipeError):
            pass


class StdioTransport(StreamTransport):
    @classmethod
    async def start(cls, argv, *, env=None, cwd=None):
        process = await asyncio.create_subprocess_exec(
            *argv, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, env=env, cwd=cwd, limit=MAX_FRAME + 1)
        result = cls(process.stdout, process.stdin)
        result.process = process
        result.stderr_bytes = 0
        async def drain():
            while True:
                data = await process.stderr.read(65536)
                if not data:
                    break
                result.stderr_bytes += len(data)
                log=paths.logs/(pathlib.Path(argv[0]).name+'-'+str(process.pid)+'.stderr.log')
                with log.open('ab') as f:f.write(data)
                log.chmod(0o600)
        result.stderr_task = asyncio.create_task(drain())
        return result

    async def close(self):
        await super().close()
        try:
            await asyncio.wait_for(self.process.wait(), 8)
        except asyncio.TimeoutError:
            # This Process was created by this transport. Do not leave an owned
            # child behind after failed startup or explicit Core shutdown.
            try:self.process.terminate()
            except ProcessLookupError:pass
            try:await asyncio.wait_for(self.process.wait(),2)
            except asyncio.TimeoutError:
                try:self.process.kill()
                except ProcessLookupError:pass
                await asyncio.wait_for(self.process.wait(),2)
        if self.process.returncode is not None:
            await self.stderr_task


class UnixJsonTransport(StreamTransport):
    @classmethod
    async def connect(cls, path):
        reader, writer = await asyncio.open_unix_connection(path, limit=MAX_FRAME + 1)
        return cls(reader, writer)


class UnixWebSocketTransport:
    """RFC6455 client over AF_UNIX, including fragmentation, ping, and bounds."""
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.write_lock = asyncio.Lock()

    @classmethod
    async def connect(cls, path, *, timeout=8):
        reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(path, limit=32768), timeout)
        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request = ("GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                   "Connection: Upgrade\r\nSec-WebSocket-Key: " + key +
                   "\r\nSec-WebSocket-Version: 13\r\n\r\n")
        try:
            writer.write(request.encode("ascii"))
            await writer.drain()
            raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), timeout)
            if len(raw) > 32768:
                raise RpcFailure(message="Unix 控制接口握手过大")
            lines = raw.decode("latin-1").split("\r\n")
            if len(lines[0].split()) < 2 or lines[0].split()[1] != "101":
                raise RpcFailure(message="Unix 控制接口拒绝 WebSocket 升级")
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    name, value = line.split(":", 1)
                    headers[name.lower()] = value.strip()
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            if (headers.get("sec-websocket-accept") != expected
                    or headers.get("upgrade", "").lower() != "websocket"
                    or "upgrade" not in headers.get("connection", "").lower()):
                raise RpcFailure(message="Unix 控制接口握手校验失败")
            return cls(reader, writer)
        except BaseException:
            writer.close()
            await writer.wait_closed()
            raise

    async def frame(self, opcode, payload):
        if len(payload) > MAX_FRAME:
            raise RpcFailure(-32602, "请求超过大小上限")
        async with self.write_lock:
            size = len(payload)
            header = bytes([0x80 | opcode])
            header += (bytes([0x80 | size]) if size < 126 else
                       bytes([0x80 | 126]) + struct.pack("!H", size) if size < 65536 else
                       bytes([0x80 | 127]) + struct.pack("!Q", size))
            mask = secrets.token_bytes(4)
            masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
            self.writer.write(header + mask + masked)
            await self.writer.drain()

    async def send(self, text):
        await self.frame(1, text.encode("utf-8"))

    async def receive(self):
        chunks, total, started = [], 0, False
        while True:
            try:
                first, second = await self.reader.readexactly(2)
            except asyncio.IncompleteReadError:
                return None
            fin, opcode = bool(first & 0x80), first & 0x0f
            if first & 0x70 or second & 0x80:
                raise RpcFailure(message="Unix 控制接口返回非法 WebSocket 帧")
            size = second & 0x7f
            if size == 126:
                size = struct.unpack("!H", await self.reader.readexactly(2))[0]
            elif size == 127:
                size = struct.unpack("!Q", await self.reader.readexactly(8))[0]
            if size > MAX_FRAME or total + size > MAX_FRAME:
                raise RpcFailure(message="后端消息超过大小上限")
            if opcode >= 8 and (not fin or size > 125):
                raise RpcFailure(message="非法 WebSocket 控制帧")
            payload = await self.reader.readexactly(size)
            if opcode == 8:
                return None
            if opcode == 9:
                await self.frame(10, payload)
                continue
            if opcode == 10:
                continue
            if opcode == 1 and not started:
                started = True
            elif opcode != 0 or not started:
                raise RpcFailure(message="不支持的 WebSocket 消息类型")
            chunks.append(payload)
            total += len(payload)
            if fin:
                return b"".join(chunks).decode("utf-8")

    async def close(self):
        try:
            await self.frame(8, struct.pack("!H", 1000))
        except (OSError, ConnectionError):
            pass
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except OSError:
            pass


class RpcClient:
    def __init__(self, transport, *, notifications=None, requests=None, disconnected=None, jsonrpc=False):
        self.transport = transport
        self.notifications, self.requests, self.disconnected = notifications, requests, disconnected
        self.jsonrpc = jsonrpc
        self.pending = {}
        self.server_tasks = set()
        self.sequence = 0
        self.write_lock = asyncio.Lock()
        self.closed = False
        # The product adapter enables this only after its nonce handshake.
        self.public_error_messages = False
        self.reader_task = asyncio.create_task(self.read_loop())

    async def send(self, value):
        if self.closed:
            raise RpcFailure(message="官方后端连接已断开")
        if self.jsonrpc:
            value = {"jsonrpc": "2.0", **value}
        text = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
        if len(text.encode("utf-8")) > MAX_FRAME:
            raise RpcFailure(-32602, "请求超过大小上限")
        async with self.write_lock:
            await self.transport.send(text)

    async def request(self, method, params=None, *, timeout=30):
        self.sequence += 1
        identifier = "organic-" + str(self.sequence)
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        sent = False
        try:
            # Validate/serialize before declaring that a write may have crossed
            # a transport boundary. Any transport send failure is ambiguous.
            value = {"id": identifier, "method": method, "params": params or {}}
            raw = json.dumps(value, ensure_ascii=False, allow_nan=False).encode("utf-8")
            if len(raw) > MAX_FRAME:
                raise RpcFailure(-32602, "请求超过大小上限")
            sent = True
            await self.send(value)
            return await asyncio.wait_for(future, timeout)
        except asyncio.TimeoutError as exc:
            raise RpcFailure(-32001, "官方后端响应超时", sent=sent) from exc
        except RpcFailure as exc:
            if exc.code not in (-32601, -32602) and sent:
                exc.sent = True
            raise
        except (OSError, ConnectionError) as exc:
            raise RpcFailure(-32002, "官方后端连接已断开", sent=sent) from exc
        finally:
            self.pending.pop(identifier, None)

    async def notify(self, method, params=None):
        await self.send({"method": method, "params": params or {}})

    async def serve_request(self, message):
        try:
            if self.requests is None:
                raise RpcFailure(-32601, "原生界面暂不支持此后端请求")
            result = await self.requests(message)
            await self.send({"id": message["id"], "result": result})
        except RpcFailure as exc:
            if not self.closed:
                await self.send({"id": message["id"], "error": {"code": exc.code, "message": exc.message}})
        except asyncio.CancelledError:
            pass
        except Exception as exc:
            diagnostic('serve_request',exc)
            if not self.closed:
                await self.send({"id": message["id"], "error": {"code": -32603, "message": type(exc).__name__+': '+str(exc)}})

    async def read_loop(self):
        try:
            while True:
                raw = await self.transport.receive()
                if raw is None:
                    break
                value = json.loads(raw)
                if not isinstance(value, dict):
                    raise RpcFailure(message="官方后端返回非法消息")
                if "method" in value and "id" in value:
                    task = asyncio.create_task(self.serve_request(value))
                    self.server_tasks.add(task)
                    task.add_done_callback(self.server_tasks.discard)
                elif "method" in value:
                    if self.notifications is not None:
                        await self.notifications(value)
                elif "id" in value:
                    future = self.pending.get(value["id"])
                    if future is None or future.done():
                        continue
                    if "error" in value:
                        future.set_exception(response_failure(value["error"], public_message=self.public_error_messages))
                    elif "result" in value:
                        future.set_result(value["result"])
                    else:
                        future.set_exception(RpcFailure(message="官方后端响应缺少结果"))
        except asyncio.CancelledError:
            return
        except Exception as exc:
            diagnostic('read_loop',exc)
        finally:
            was_open = not self.closed
            self.closed = True
            for future in list(self.pending.values()):
                if not future.done():
                    future.set_exception(RpcFailure(-32002, "官方后端连接已断开", sent=True))
            if was_open and self.disconnected is not None:
                await self.disconnected()

    async def close(self):
        self.closed = True
        for task in list(self.server_tasks):
            task.cancel()
        await self.transport.close()
        if self.reader_task is not asyncio.current_task():
            self.reader_task.cancel()
            await asyncio.gather(self.reader_task, return_exceptions=True)
