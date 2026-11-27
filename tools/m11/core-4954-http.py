#!/usr/bin/env python3
"""Real Core HTTP envelope + RpcClient, queue-only fake App Server. python -I."""
import asyncio
import copy
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
p.add_argument('--model-list', action='store_true', help='Check model catalog defaults with a paginated fake backend')
p.add_argument('--browser-navigation', type=Path, help='Exercise owned Chromium navigation against a local fixture')
a = p.parse_args()
if a.baseline:
    import core as core_module
    import transport as transport_module
    original = json.loads(a.baseline.read_text())
    methods = [(Core, core_module, 'rpc' if a.model_list else 'http', 'Runtime/Core/core.py')]
    if not a.model_list:
        methods.append((RpcClient, transport_module, 'request', 'Runtime/Core/transport.py'))
    for cls, module, name, path in methods:
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


class ModelCatalogTransport(FakeAppTransport):
    def __init__(self, pages):
        super().__init__(None)
        self.pages = pages

    async def send(self, raw):
        message = json.loads(raw)
        assert message['method'] == 'model/list', 'only model metadata is allowed in this fixture'
        params = message['params']
        assert params['includeHidden'] is True and params['limit'] == 2
        result = self.pages[params.get('cursor')]
        await self.incoming.put(json.dumps({'id': message['id'], 'result': result}))


async def model_list():
    from types import SimpleNamespace

    pages = {
        None: {'data': [{'id': 'old', 'model': 'wire-old', 'isDefault': True, 'displayName': 'Old default'}],
               'nextCursor': 'second', 'fixtureMetadata': {'unknown': None}},
        'second': {'data': [{'id': 'alias', 'model': 'wire-preferred', 'isDefault': False, 'serviceTiers': ['fast']},
                            {'id': 'other', 'model': 'wire-other', 'isDefault': False}], 'nextCursor': 'last'},
        'last': {'data': [{'id': 'another-alias', 'model': 'wire-preferred', 'isDefault': False}], 'nextCursor': None}
    }
    preferred = copy.deepcopy(pages)
    preferred[None]['data'][0]['isDefault'] = False
    preferred['second']['data'][0]['isDefault'] = True
    cases = [
        ('wire-preferred', preferred, 'model/list selects the configured wire model as the sole default across pages'),
        ('wire-absent', pages, 'model/list preserves every backend field when the configured model is absent'),
    ]
    findings = 0
    for model, expected, label in cases:
        core = Core.__new__(Core)
        core.args = SimpleNamespace(model=model)
        core.app = RpcClient(ModelCatalogTransport(pages))
        core.routes = {}
        try:
            received = {}
            for cursor in pages:
                params = {'includeHidden': True, 'limit': 2}
                if cursor is not None:
                    params['cursor'] = cursor
                status, body = await http(core, 'model/list', params)
                assert status.startswith('HTTP/1.1 200'), body
                received[cursor] = body['result']
            if received != expected:
                findings += 1
                defaults = [row['id'] for page in received.values() for row in page['data'] if row.get('isDefault')]
                print(f'FINDING: {label} (returned defaults={defaults})')
            else:
                print('PASS ' + label)
        finally:
            await core.app.close()
    print(f'CORE_MODEL_LIST: {len(cases)} checks, {findings} findings')
    return bool(findings)


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


async def browser_navigation(output):
    import types
    from adapters.browser import adapter
    from runtime_paths import paths
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'm1146'))
    from browser_navigation_fixture import PAGES

    output.mkdir(parents=True, exist_ok=True)
    work = output / 'work'
    work.mkdir(exist_ok=True)
    paths.configure(data_dir=output / 'private', work_root=work)
    paths.prepare()
    core = Core.__new__(Core)
    core.routes = {}
    core.adapters = {}
    core.args = types.SimpleNamespace(proxy=None)
    core.work = work
    events = []
    core.emit = lambda method, params: events.append({'method': method, 'params': params})
    await adapter.register(core)
    checks = []
    page_requests = []

    def check(value, name):
        checks.append({'name': name, 'passed': bool(value)})
        if not value:
            print('FINDING: ' + name, flush=True)

    async def request(method, path, body=None):
        payload = json.dumps(body or {}).encode()
        reader = asyncio.StreamReader()
        header = f'{method} {path} HTTP/1.1\r\nContent-Length: {len(payload)}\r\n\r\n'
        reader.feed_data(header.encode() + payload)
        reader.feed_eof()
        writer = Writer()
        await core.http(reader, writer)
        _, raw = bytes(writer.raw).split(b'\r\n\r\n', 1)
        return json.loads(raw)

    async def page(reader, writer):
        try:
            header = await reader.readuntil(b'\r\n\r\n')
            path = header.split(b' ', 2)[1].decode()
            page_requests.append(path)
            content = PAGES.get(path, '<!doctype html><title>Not found</title><body>Not found</body>')
            raw = content.encode()
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n'
                         + f'Content-Length: {len(raw)}\r\nConnection: close\r\n\r\n'.encode() + raw)
            await writer.drain()
        finally:
            writer.close()

    server = await asyncio.start_server(page, '127.0.0.1', 0)
    port = server.sockets[0].getsockname()[1]
    initial_schema = core.adapters['organic_browser']['tools'][0]['inputSchema']
    check(initial_schema['properties']['action']['enum'] ==
          ['discover', 'new', 'snapshot', 'fill', 'click', 'screenshot', 'close'],
          'navigation routes do not extend the model tool schema')
    try:
        for action in ['back', 'forward', 'reload']:
            response = await request('POST', '/browser/' + action, {'tabId': 'missing'})
            check(response.get('error', {}).get('code') == -32004,
                  action + ' before runtime startup returns -32004')
        check(not events, 'unstarted navigation routes do not start the browser runtime')
        opened = await request('POST', '/browser/open', {'url': f'http://127.0.0.1:{port}/first'})
        check('result' in opened, 'local first page opens through the real Core HTTP route')
        identifier = opened['result']['tabId']
        snapshots = []

        async def history(path, back, forward):
            response = None
            for _ in range(100):
                response = await request('GET', '/browser/tabs')
                values = response.get('result', {}).get('tabs', [])
                if values and values[0]['url'].endswith(path):
                    break
                await asyncio.sleep(.05)
            snapshots.append(response)
            values = response.get('result', {}).get('tabs', [])
            check(len(values) == 1 and values[0]['tabId'] == identifier and values[0]['url'].endswith(path),
                  'authoritative tabs reaches ' + path)
            check(values and values[0].get('canGoBack') is back and values[0].get('canGoForward') is forward,
                  'CDP history flags match ' + path + f' back={back} forward={forward}')

        await history('/second', True, False)
        for action, path, back, forward in [
            ('back', '/first', False, True), ('forward', '/second', True, False),
            ('reload', '/second', True, False), ('forward', '/second', True, False),
            ('back', '/first', False, True), ('back', '/first', False, True),
        ]:
            count = page_requests.count('/second')
            response = await request('POST', '/browser/' + action, {'tabId': identifier})
            check('result' in response and response['result']['tabId'] == identifier,
                  action + ' returns normally for the owned tab')
            await history(path, back, forward)
            if action == 'reload':
                check(page_requests.count('/second') == count + 1, 'reload loads the second local page again')
        for action in ['back', 'forward', 'reload']:
            response = await request('POST', '/browser/' + action, {'tabId': 'missing'})
            check(response.get('error', {}).get('code') == -32000,
                  action + ' rejects an unknown owned tab')
        await request('POST', '/browser/close', {'tabId': identifier})
        response = await request('GET', '/browser/tabs')
        check(response.get('result', {}).get('tabs') == [], 'closed pages disappear after CDP session cleanup')
        (output / 'history.json').write_text(json.dumps(snapshots, indent=2) + '\n')
    finally:
        server.close()
        await server.wait_closed()
        for registered in core.adapters.values():
            if registered['close']:
                await registered['close']()
    failures = [entry['name'] for entry in checks if not entry['passed']]
    receipt = {'checks': len(checks), 'failures': failures, 'pageRequests': page_requests, 'events': events}
    (output / 'results.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(f'CORE_BROWSER_NAVIGATION: {len(checks)} checks, {len(failures)} findings')
    return bool(failures)


if __name__ == '__main__':
    if a.model_list:
        operation = model_list()
    else:
        operation = browser_navigation(a.browser_navigation) if a.browser_navigation else main()
    raise SystemExit(asyncio.run(operation))
