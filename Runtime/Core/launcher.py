"""Start, inspect or stop this local Core; never stop a process by a stale PID."""
import sys
sys.dont_write_bytecode = True
import argparse
import json
import os
import subprocess
import time
import urllib.error
import urllib.request
from runtime_paths import paths, SOURCE


def request(port, route, body=None):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    req = urllib.request.Request('http://127.0.0.1:'+str(port)+route,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Content-Type': 'application/json'})
    with opener.open(req, timeout=2) as response:
        return json.load(response)['result']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['start', 'status', 'stop'])
    parser.add_argument('--port', type=int, default=int(os.environ.get('ORGANIC_CORE_PORT', '18793')))
    parser.add_argument('--data-dir')
    parser.add_argument('--work-root')
    parser.add_argument('--resources')
    args, extra = parser.parse_known_args()
    paths.configure(args.data_dir, args.work_root, args.resources)
    try:
        health = request(args.port, '/health')
    except (OSError, urllib.error.URLError):
        health = None
    if health and (health.get('name') != 'Organic Codex Core' or health.get('dataDir') != str(paths.data)):
        raise SystemExit('Port is occupied by a different Core instance; select its data directory or another port.')
    if args.command == 'status':
        print(json.dumps(health or {'running': False}, ensure_ascii=False, indent=2)); return
    if args.command == 'stop':
        print(json.dumps(request(args.port, '/shutdown', {}) if health else {'running': False})); return
    if health:
        print(json.dumps(health, ensure_ascii=False)); return
    paths.prepare()
    argv = [sys.executable, '-B', str(SOURCE/'core.py'), '--port', str(args.port),
            '--data-dir', str(paths.data), '--work-root', str(paths.work), '--resources', str(paths.resources), *extra]
    with (paths.logs/'core.stdout.log').open('ab') as log:
        process = subprocess.Popen(argv, cwd=paths.work, stdout=log, stderr=subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, start_new_session=True)
    (paths.data/'core.pid').write_text(str(process.pid))
    for _ in range(150):
        if process.poll() is not None:
            raise SystemExit('Core exited during startup; inspect '+str(paths.logs/'core.stdout.log'))
        try:
            health = request(args.port, '/health')
            if health['pid'] == process.pid:
                print(json.dumps(health, ensure_ascii=False)); return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(.2)
    raise SystemExit('Core has not become ready; inspect '+str(paths.logs/'core.stdout.log'))


if __name__ == '__main__': main()
