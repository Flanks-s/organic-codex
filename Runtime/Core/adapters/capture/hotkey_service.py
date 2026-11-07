"""Owned, opt-in lifecycle for the already verified global Appshot listener."""
import asyncio
import json
import pathlib
import signal
import sys
from runtime_paths import paths


class HotkeyService:
    def __init__(self,core,folder):
        self.core=core;self.folder=pathlib.Path(folder)
        self.process=None;self.tasks=[];self.lock=asyncio.Lock()
        self.thread_id=None;self.mode='window';self.ready=False
        self.error=None;self.stderr='';self.stopping=False

    def status(self):
        running=self.process is not None and self.process.returncode is None
        return {'enabled':bool(running and self.ready),'threadId':self.thread_id,'mode':self.mode,
                'shortcut':'Control+Option+Command+S','pid':self.process.pid if running else None,
                'error':self.error}

    async def _stdout(self,proc,registered):
        while True:
            line=await proc.stdout.readline()
            if not line:break
            try:event=json.loads(line)
            except json.JSONDecodeError:continue
            if event.get('event')=='hotkeyRegistered':
                self.ready=event.get('success') is True and event.get('status')==0
                if not self.ready:self.error=json.dumps(event,ensure_ascii=False)
                registered.set()
                break
        # capture/send can print large attachment receipts: drain them without
        # accumulating screenshots, AX content, or an unbounded in-memory log.
        while await proc.stdout.read(65536):pass
        registered.set()

    async def _stderr(self,proc):
        while True:
            data=await proc.stderr.read(4096)
            if not data:return
            self.stderr=(self.stderr+data.decode(errors='replace'))[-2048:]

    async def _watch(self,proc):
        code=await proc.wait()
        if self.process is proc and not self.stopping:
            self.ready=False
            self.error=self.error or self.stderr.strip() or 'Hotkey listener exited ('+str(code)+')'
            self.core.emit('core/hotkeyExited',self.status())

    async def _stop(self):
        proc=self.process
        if proc is None:return
        self.stopping=True
        if proc.returncode is None:
            # hotkey.py handles SIGINT through KeyboardInterrupt/finally,
            # terminating and waiting for its owned HotkeyHelper. SIGTERM
            # would skip that Python cleanup and leave the Carbon listener.
            proc.send_signal(signal.SIGINT)
        await proc.wait()
        await asyncio.gather(*self.tasks)
        self.process=None;self.tasks=[];self.ready=False;self.stopping=False
        self.core.emit('core/hotkeyStopped',self.status())

    async def configure(self,body):
        async with self.lock:
            enabled=body['enabled']
            if type(enabled) is not bool:raise ValueError('enabled must be true or false')
            if not enabled:
                await self._stop()
                return self.status()
            tid=body.get('threadId');mode=body.get('mode','window')
            if not isinstance(tid,str) or not tid.strip():raise ValueError('threadId is required to enable the Appshot shortcut')
            if mode not in ('window','screen'):raise ValueError('mode must be window or screen')
            if self.status()['enabled'] and (tid,mode)==(self.thread_id,self.mode):return self.status()
            await self._stop()
            self.thread_id=tid;self.mode=mode;self.error=None;self.stderr=''
            endpoint='http://127.0.0.1:'+str(self.core.args.port)
            self.process=await asyncio.create_subprocess_exec(sys.executable,str(self.folder/'hotkey.py'),
                '--endpoint',endpoint,'--thread',tid,'--mode',mode,'--helper',str(paths.helpers/'HotkeyHelper'),
                stdin=asyncio.subprocess.DEVNULL,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
            proc=self.process;registered=asyncio.Event()
            self.tasks=[asyncio.create_task(self._stdout(proc,registered)),
                        asyncio.create_task(self._stderr(proc)),asyncio.create_task(self._watch(proc))]
            try:await asyncio.wait_for(registered.wait(),5)
            except asyncio.TimeoutError:self.error='Hotkey helper did not report registration within 5 seconds'
            if not self.ready:
                self.error=self.error or self.stderr.strip() or 'Hotkey helper exited before registration'
                await self._stop()
            else:self.core.emit('core/hotkeyStarted',self.status())
            return self.status()

    async def close(self):
        async with self.lock:await self._stop()
