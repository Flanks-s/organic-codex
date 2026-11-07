"""Owned PTYs with a bounded output tail; UI lifetime is independent."""
import asyncio
import codecs
from collections import deque
import errno
import fcntl
import os
from pathlib import Path
import pty
import pwd
import secrets
import signal
import struct
import termios
from transport import RpcFailure
from .git import directory

OUTPUT_LIMIT = 256 * 1024


def controlling_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class Terminals:
    def __init__(self, core):
        self.core=core; self.sessions={}; self.loop=asyncio.get_running_loop()

    def get(self, identifier):
        if identifier not in self.sessions: raise RpcFailure(-32602,'Unknown terminal session')
        return self.sessions[identifier]

    def public(self, session):
        return {key:session.get(key) for key in ('id','pid','cwd','cols','rows','running','exitCode','threadId','conversationId')}

    def size(self, cols, rows):
        if type(cols) is not int or type(rows) is not int or not (1<=cols<=1000 and 1<=rows<=1000):
            raise RpcFailure(-32602,'Terminal cols and rows must be integers from 1 to 1000')
        return struct.pack('HHHH',rows,cols,0,0)

    async def open(self, body, query=None, *, command=None):
        cwd=directory(body['cwd']); cols=body.get('cols',80);rows=body.get('rows',24)
        metadata={key:body.get(key) for key in ('threadId','conversationId')}
        if any(value is not None and (not isinstance(value,str) or not value or len(value)>256) for value in metadata.values()):
            raise RpcFailure(-32602,'Terminal threadId and conversationId must be nonempty strings of at most 256 characters')
        dimensions=self.size(cols,rows)
        if sum(s['running'] for s in self.sessions.values())>=8:
            raise RpcFailure(-32004,'Close an existing terminal before opening more than eight')
        shell=pwd.getpwuid(os.getuid()).pw_shell or '/bin/zsh'
        master,slave=pty.openpty()
        fcntl.ioctl(slave,termios.TIOCSWINSZ,dimensions)
        try:
            process=await asyncio.create_subprocess_exec(*(command or [shell,'-l']),cwd=str(cwd),
                         stdin=slave,stdout=slave,stderr=slave,preexec_fn=controlling_terminal,
                         env={**os.environ,'TERM':'xterm-256color','COLORTERM':'truecolor'})
        except BaseException:
            os.close(master);raise
        finally: os.close(slave)
        os.set_blocking(master,False)
        identifier=secrets.token_hex(12)
        session={'id':identifier,'pid':process.pid,'cwd':str(cwd),'cols':cols,'rows':rows,**metadata,
                 'running':True,'exitCode':None,'process':process,'fd':master,
                 'chunks':deque(),'bytes':0,'sequence':0,'writeLock':asyncio.Lock(),
                 'decoder':codecs.getincrementaldecoder('utf-8')('replace')}
        self.sessions[identifier]=session
        self.loop.add_reader(master,self.read,session)
        session['watcher']=asyncio.create_task(self.wait(session))
        return self.public(session)

    def output(self, session, text):
        if not text:return
        session['sequence']+=1
        chunk={'sequence':session['sequence'],'data':text};size=len(text.encode())
        session['chunks'].append((chunk,size));session['bytes']+=size
        while session['bytes']>OUTPUT_LIMIT:
            _,removed=session['chunks'].popleft();session['bytes']-=removed
        self.core.emit('core/terminalOutput',{'sessionId':session['id'],**chunk})

    def read(self, session):
        fd=session['fd']
        if fd is None:return
        try:data=os.read(fd,65536)
        except BlockingIOError:return
        except OSError as error:
            if error.errno not in (errno.EIO,errno.EBADF):raise
            data=b''
        if data:
            self.output(session,session['decoder'].decode(data));return
        self.detach(session)

    def detach(self, session):
        if session['fd'] is not None:
            self.loop.remove_reader(session['fd']);os.close(session['fd']);session['fd']=None
            self.output(session,session['decoder'].decode(b'',final=True))

    async def wait(self, session):
        code=await session['process'].wait()
        # Drain remaining bytes before publishing the exit event.
        while session['fd'] is not None:
            before=session['sequence'];self.read(session)
            if before==session['sequence']:break
        self.detach(session)
        session.update(running=False,exitCode=code)
        session['sequence']+=1
        self.core.emit('core/terminalExited',{'sessionId':session['id'],'exitCode':code,'sequence':session['sequence']})

    async def list(self, body, query):return [self.public(s) for s in self.sessions.values()]

    async def write(self, body, query):
        session=self.get(body['id']);data=body['data']
        if not isinstance(data,str) or len(data.encode())>65536:
            raise RpcFailure(-32602,'Terminal write requires text of at most 64 KiB')
        if not session['running'] or session['fd'] is None:raise RpcFailure(-32004,'Terminal has exited')
        raw=data.encode();total=len(raw)
        async with session['writeLock']:
            while raw:
                if session['fd'] is None:raise RpcFailure(-32004,'Terminal has exited')
                try: written=os.write(session['fd'],raw);raw=raw[written:]
                except BlockingIOError:
                    ready=self.loop.create_future();fd=session['fd']
                    self.loop.add_writer(fd,lambda:ready.done() or ready.set_result(None))
                    try:await asyncio.wait_for(ready,5)
                    finally:self.loop.remove_writer(fd)
        return {'id':session['id'],'written':total}

    async def resize(self, body, query):
        session=self.get(body['id']);dimensions=self.size(body['cols'],body['rows'])
        if not session['running'] or session['fd'] is None:raise RpcFailure(-32004,'Terminal has exited')
        fcntl.ioctl(session['fd'],termios.TIOCSWINSZ,dimensions)
        session.update(cols=body['cols'],rows=body['rows'])
        return self.public(session)

    async def close_one(self, body, query=None):
        session=self.get(body['id'])
        if session['running']:
            self.detach(session)
            # Closing the controlling PTY already sends HUP to its foreground
            # group. Let the watcher observe that exit before escalating; a raw
            # killpg here can race a departed/zombie group on macOS (EPERM).
            try:
                await asyncio.wait_for(asyncio.shield(session['watcher']),.25)
                return self.public(session)
            except asyncio.TimeoutError:pass
            for sig,timeout in ((signal.SIGHUP,2),(signal.SIGTERM,2),(signal.SIGKILL,2)):
                if session['process'].returncode is not None:break
                # The subprocess handle checks reaping before signalling its
                # owned child. Never signal a cached process-group number.
                try:session['process'].send_signal(sig)
                except ProcessLookupError:break
                try:await asyncio.wait_for(asyncio.shield(session['watcher']),timeout);break
                except asyncio.TimeoutError:pass
            await session['watcher']
        return self.public(session)

    async def catchup(self, body, query):
        identifier=body.get('id') or query.get('id',[None])[0]
        since=int(body.get('since',query.get('since',['0'])[0]))
        session=self.get(identifier);chunks=[chunk for chunk,_ in session['chunks']]
        first=chunks[0]['sequence'] if chunks else session['sequence']+1
        return {'id':identifier,'chunks':[c for c in chunks if c['sequence']>since],
                'firstSequence':first,'lastSequence':session['sequence'],
                'truncated':bool(chunks and since<first-1),'running':session['running'],
                'exitCode':session['exitCode'],'maxBufferBytes':OUTPUT_LIMIT}

    async def close(self):
        await asyncio.gather(*(self.close_one({'id':key}) for key in self.sessions))
