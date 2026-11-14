#!/usr/bin/env python3
"""Real Core HTTP envelope + RpcClient, queue-only fake App Server. python -I."""
import asyncio
import json
from pathlib import Path
import sys
import argparse
import inspect
import textwrap
import ast
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'Runtime/Core'))
from core import Core
from transport import RpcClient, RpcFailure

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--mutate-sent', action='store_true')
p.add_argument('--baseline', type=Path)
a = p.parse_args()
if a.baseline:
    import core as core_module
    import transport as transport_module
    original = json.loads(a.baseline.read_text())
    for cls, module, name, path in [(Core, core_module, 'http', 'Runtime/Core/core.py'), (RpcClient, transport_module, 'request', 'Runtime/Core/transport.py')]:
        definition = next(n for n in ast.parse(original[path]).body if isinstance(n, ast.ClassDef) and n.name == cls.__name__)
        method = next(n for n in definition.body if isinstance(n, ast.AsyncFunctionDef) and n.name == name)
        scope = dict(vars(module))
        exec(compile(ast.Module(body=[method], type_ignores=[]), '<baseline-' + name + '>', 'exec'), scope)
        setattr(cls, name, scope[name])
if a.mutate_sent:
    import core as core_module
    source = textwrap.dedent(inspect.getsource(Core.http))
    old = "'requestSent':getattr(e,'sent',None)"
    assert source.count(old) == 1
    scope = dict(vars(core_module))
    exec(compile(source.replace(old, "'requestSent':None"), '<mutation-49-http>', 'exec'), scope)
    Core.http = scope['http']


class FakeAppTransport:
    def __init__(self, code):
        self.code = code
        self.incoming = asyncio.Queue()
        self.sent = []
        self.receipts = []

    async def send(self, raw):
        message = json.loads(raw); self.sent.append(message)
        if message['method'] == 'turn/start':
            if self.code != -32602:
                self.receipts.append({'id': 'synthetic-user', 'type': 'userMessage', 'clientId': message['params']['clientUserMessageId']})
            response = {'error': {'code': self.code, 'message': '不透明消息', 'data': {'opaque': 7}}}
        else:
            assert message['method'] == 'thread/read', 'real inference forbidden'
            response = {'result': {'thread': {'id': 'synthetic', 'turns': [{'id': 'accepted', 'status': 'completed', 'items': self.receipts}]}}}
        await self.incoming.put(json.dumps({'id': message['id'], **response}))

    async def receive(self): return await self.incoming.get()
    async def close(self): pass


class Writer:
    def __init__(self): self.raw = bytearray()
    def write(self, data): self.raw.extend(data)
    async def drain(self): pass
    def close(self): pass


async def http(core, method, params):
    body = json.dumps({'method': method, 'params': params}).encode()
    reader = asyncio.StreamReader()
    reader.feed_data(b'POST /rpc HTTP/1.1\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
    reader.feed_eof(); writer = Writer()
    await core.http(reader, writer)
    header, payload = bytes(writer.raw).split(b'\r\n\r\n', 1)
    return header.split(b'\r\n')[0].decode(), json.loads(payload)


async def main():
    findings = []
    for code in [-32001, -32002, -32000, -32602]:
        transport = FakeAppTransport(code); client = RpcClient(transport)
        core = Core.__new__(Core)
        core.sessions = {'synthetic': {'loaded': True}}
        core.app = client; core.routes = {}; core.persist = lambda: None
        try:
            status, result = await http(core, 'turn/start', {'threadId': 'synthetic', 'input': [{'type': 'text', 'text': 'fixture'}], 'clientUserMessageId': 'same-client'})
            error = result['error']; expected = True
            if error.get('requestSent') is not expected:
                findings.append(f'#49 {code}: requestSent={error.get("requestSent")!r}, expected {expected}')
            assert error['data'] == {'opaque': 7}, 'opaque error data must survive'
            read_status, read = await http(core, 'thread/read', {'threadId': 'synthetic'})
            assert read_status.startswith('HTTP/1.1 200')
            items = read['result']['thread']['turns'][0]['items']
            assert items == [] if code == -32602 else items[0]['clientId'] == 'same-client'
            assert sum(m['method'] == 'turn/start' for m in transport.sent) == 1
            print(json.dumps({'code': code, 'status': status, 'error': error, 'receipt': 'same-client' if items else None, 'writes': 1}, ensure_ascii=False))
        finally: await client.close()
    transport = FakeAppTransport(-32602); client = RpcClient(transport)
    core = Core.__new__(Core); core.sessions = {}; core.app = client; core.routes = {}
    try:
        _, result = await http(core, 'turn/start', {'threadId': 'not-resumed'})
        if result['error'].get('requestSent') is not False: findings.append('#49 local refusal must report requestSent=false')
        assert transport.sent == [], 'local refusal must not reach fake App Server'
        print(json.dumps({'localRejection': result, 'writes': 0}, ensure_ascii=False))
    finally: await client.close()
    for finding in findings: print('FINDING: ' + finding)
    print(f'CORE_4954_HTTP: 5 cases, {len(findings)} findings')
    return bool(findings)


if __name__ == '__main__': raise SystemExit(asyncio.run(main()))
