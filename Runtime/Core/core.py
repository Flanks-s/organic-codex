"""Headless App Server + official CUA, HTTP JSON and replayable SSE. Python 3.9+."""
import sys
sys.dont_write_bytecode = True
import argparse, asyncio, base64, copy, importlib, json, os, pathlib, secrets, signal, socket, time, uuid
from urllib.parse import urlsplit, parse_qs
from transport import RpcClient, StdioTransport, RpcFailure
from lab_common import environment, processes, convert_result
from runtime_paths import paths, DEFAULT_MODULES
from capabilities import capabilities
from event_log import EventLog
from authorizations import SessionAuthorizations

ROOT = pathlib.Path(__file__).resolve().parent
NS = 'organic_cua'
def encode(v): return json.dumps(v, ensure_ascii=False, separators=(',', ':')).encode()

class AppRpc(RpcClient):
    async def send(self, value):
        context = self.core.tool_context.get(value.get('id')) if 'result' in value else None
        if context and self.core.retired(context):
            self.core.emit('core/lateResultDiscarded', context)
            value = {'id':value['id'], 'error':{'code':-32003,'message':'Turn retired; late result discarded'}}
        try:await super().send(value)
        finally:
            if 'id' in value and ('result' in value or 'error' in value):self.core.tool_context.pop(value['id'],None)

class Core:
    def __init__(self, args):
        self.args=args
        paths.configure(getattr(args,'data_dir',None),getattr(args,'work_root',None),getattr(args,'resources',None)); paths.prepare()
        self.data=paths.data; self.work=paths.work
        # Local process identity only; this nonce is not HTTP authentication.
        self.instance_id=str(uuid.uuid4())
        identity=self.data/'runtime-instance.json'
        temporary=identity.with_suffix('.tmp')
        temporary.write_bytes(encode({'pid':os.getpid(),'instanceId':self.instance_id}))
        os.chmod(temporary,0o600);temporary.replace(identity)
        self.changed=asyncio.Event(); self.done=asyncio.Event()
        self.log=EventLog(self.data/'events.jsonl',getattr(args,'event_tail_count',128),getattr(args,'event_tail_bytes',2*1024*1024))
        self.sessions_path=self.data/'sessions.json'
        self.sessions=json.loads(self.sessions_path.read_text()) if self.sessions_path.exists() else {}
        for s in self.sessions.values(): s.update(active=None, loaded=False)
        self.dead=set(); self.tool_context={}; self.inflight={}; self.cua={}; self.cua_locks={}
        self.approvals={}; self.operations=set(); self.app=None; self.app_transport=None
        self._closed=False
        self.authorizations=SessionAuthorizations(self.data/'authorizations.json')
        if not self.authorizations.exists:
            for event in self.log.since(0):
                if event['method']=='core/approvalResponded':
                    public=event['params']
                    if public.get('threadId') in self.sessions:self.authorizations.learn(public,public['response'])
            self.authorizations.persist()
        self.adapters={}; self.routes={}
    def register_adapter(self,namespace,description,tools,handler,close=None,interrupt=None):
        self.adapters[namespace]={'description':description,'tools':tools,'handler':handler,'close':close,'interrupt':interrupt}
    def register_route(self,method,path,handler):self.routes[(method,path)]=handler
    @property
    def spec(self):
        return [{'type':'namespace','name':name,'description':adapter['description'],'tools':adapter['tools']} for name,adapter in self.adapters.items() if adapter['tools']]
    def persist(self):
        temp=self.sessions_path.with_suffix('.tmp'); temp.write_bytes(encode(self.sessions)); os.chmod(temp,0o600); temp.replace(self.sessions_path)
    def emit(self, method, params, **extra):
        entry=self.log.append({'time':time.time(),'method':method,'params':params,**extra})
        old=self.changed; self.changed=asyncio.Event(); old.set()
        return entry
    def retired(self,p): return p.get('_retiredCuaCall',False) or (p.get('threadId'),p.get('turnId')) in self.dead
    async def notification(self,msg):
        p=msg.get('params') or {}; tid=p.get('threadId'); method=msg.get('method')
        if tid in self.sessions and method in ('turn/started','turn/completed'):
            s=self.sessions[tid]; turn=p['turn']; s['lastTurn']=turn
            if method=='turn/started': s['active']=turn['id']
            elif s.get('active')==turn['id']: s['active']=None
            if method=='turn/completed':
                self.dead.add((tid,turn['id']))
                self.expire_approvals(tid,turn['id'])
            self.persist()
        if method=='serverRequest/resolved':
            for a in list(self.approvals.values()):
                original=a['public']
                if original['source']=='app-server' and original['request']['id']==p.get('requestId') and original.get('threadId')==tid:
                    self.expire_approval(a,'server-request-resolved')
        self.emit(method,p,**{k:v for k,v in msg.items() if k not in ('method','params')})
    def expire_approval(self,a,reason):
        if a.get('expired'):return
        a.update(expired=True,expiredReason=reason);p=a['public']
        self.emit('core/approvalExpired',{'approvalId':p['approvalId'],'threadId':p.get('threadId'),'turnId':p.get('turnId'),'reason':reason})
        if not a['future'].done():a['future'].set_exception(RpcFailure(-32003,'Approval expired: '+reason))
    def expire_approvals(self,tid,turn,reason='turn-ended'):
        for a in list(self.approvals.values()):
            p=a['public']
            if p.get('threadId')==tid and p.get('turnId')==turn:self.expire_approval(a,reason)
    async def approval(self,msg,source,thread_id=None,context=None):
        if source=='cua' and not context:raise RpcFailure(-32003,'CUA approval has no active tool request')
        if context and self.retired(context): raise RpcFailure(-32003,'Retired turn cannot request approval')
        grant=self.authorizations.matching(thread_id,msg,source)
        if grant:
            response=copy.deepcopy(grant['response'])
            self.emit('core/approvalReused',{'threadId':thread_id,'turnId':(context or {}).get('turnId'),'grantId':grant['id'],'app':grant['app'],'request':msg,'response':response})
            return response
        aid=secrets.token_hex(8); future=asyncio.get_running_loop().create_future()
        p=msg.get('params') or {}; meta=p.get('_meta') or {}; app=(meta.get('tool_params') or {}).get('app')
        public={'approvalId':aid,'source':source,'request':msg,'threadId':thread_id,'turnId':(context or {}).get('turnId'),'callId':(context or {}).get('callId')}
        entry={'future':future,'public':public};self.approvals[aid]=entry
        self.emit('core/approvalRequested',public)
        if source=='cua' and context and not self.retired(context) and msg.get('method')=='elicitation/create' and meta.get('connector_id')=='computer-use' and app in self.args.allow_test_app:
            future.set_result({'action':'accept','content':{},'_meta':{'persist':'session'}})
        try:
            response=await future
            if entry.get('expired'):raise RpcFailure(-32003,'Approval expired: '+entry['expiredReason'])
            if context and self.retired(context): raise RpcFailure(-32003,'Approval arrived after turn retirement')
            self.emit('core/approvalResponded',{**public,'response':response})
            grant=self.authorizations.learn(public,response)
            if grant:self.emit('core/authorizationGranted',{'threadId':thread_id,'grant':grant})
            return response
        finally: self.approvals.pop(aid,None)
    async def get_cua(self,tid):
        if tid not in self.cua:
            async def callback(msg):
                active=next((p for p in self.inflight.values() if p['threadId']==tid),None)
                return await self.approval(msg,'cua',tid,active)
            tr=await StdioTransport.start([str(paths.resources/'cua_node/bin/node'),str(paths.modules/'@oai/cua-repl/bin/cua-repl.mjs')],env=environment(),cwd=str(self.work))
            rpc=RpcClient(tr,requests=callback,jsonrpc=True)
            await rpc.request('initialize',{'protocolVersion':'2025-06-18','capabilities':{'elicitation':{'form':{}}},'clientInfo':{'name':'organic-core','version':'0.1'}})
            await rpc.notify('notifications/initialized')
            self.cua[tid]=(rpc,tr); self.emit('core/cuaStarted',{'threadId':tid,'pid':tr.process.pid})
        return self.cua[tid][0]
    async def server_request(self,msg):
        p=msg.get('params') or {}; tid=p.get('threadId')
        if msg.get('method')!='item/tool/call': return await self.approval(msg,'app-server',tid,p)
        self.tool_context[msg['id']]=p
        adapter=self.adapters.get(p.get('namespace'))
        if not adapter or p.get('tool') not in [x['name'] for x in adapter['tools']]:raise RpcFailure(-32601,'Unknown dynamic tool')
        if self.retired(p):raise RpcFailure(-32003,'Turn retired before adapter dispatch')
        result=await adapter['handler'](msg)
        if self.retired(p):
            self.emit('core/lateResultDiscarded',p);raise RpcFailure(-32003,'Turn retired before adapter result')
        return result
    async def cua_call(self,msg):
        p=msg['params'];tid=p['threadId']
        lock=self.cua_locks.setdefault(tid,asyncio.Lock())
        async with lock:
            if self.retired(p): raise RpcFailure(-32003,'Turn retired before tool dispatch')
            rpc=await self.get_cua(tid)
            if self.retired(p): raise RpcFailure(-32003,'Turn retired while CUA initialized')
            params={'name':p['tool'],'arguments':copy.deepcopy(p['arguments'])}
            if '_meta' in msg: params['_meta']=copy.deepcopy(msg['_meta'])
            elif '_meta' in p: params['_meta']=copy.deepcopy(p['_meta'])
            self.inflight[p['callId']]={**p,'mcpRequestId':'organic-'+str(rpc.sequence+1)}
            self.emit('core/toolRequested',{'threadId':tid,'turnId':p['turnId'],'request':msg,'forwardedParams':params})
            try:
                raw=await rpc.request('tools/call',params,timeout=180)
                reply,evidence,images=convert_result(raw,p['callId'])
                self.emit('core/toolResult',{'threadId':tid,'turnId':p['turnId'],'callId':p['callId'],'raw':raw,'images':images,'retired':self.retired(p)})
                if self.retired(p):
                    self.emit('core/lateResultDiscarded',p); raise RpcFailure(-32003,'Turn retired; late result retained only as evidence')
                return reply
            except RpcFailure as error:
                if error.code == -32001:
                    # A capture is not the whole chat/turn. Expire only the timed-out invocation.
                    self.inflight[p['callId']]['_retiredCuaCall']=True
                    for approval in list(self.approvals.values()):
                        public=approval['public']
                        if public.get('source')=='cua' and public.get('threadId')==tid and public.get('callId')==p['callId']:
                            self.expire_approval(approval,'cua-call-timeout')
                    request_id=self.inflight[p['callId']]['mcpRequestId']
                    try: await rpc.notify('notifications/cancelled',{'requestId':request_id,'reason':'CUA call timed out'})
                    except Exception as cancel_error: self.emit('core/cuaCancelFailed',{'threadId':tid,'callId':p['callId'],'error':str(cancel_error)})
                raise
            finally: self.inflight.pop(p['callId'],None)
    async def start(self):
        if not paths.cli.is_file(): raise RuntimeError('Official App Server CLI not found: '+str(paths.cli))
        self.emit('core/processes',processes())
        env=environment()
        if self.args.proxy:
            env.update({k:self.args.proxy for k in ('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy')})
            env['NO_PROXY']='localhost,127.0.0.1,::1'
        self.app_transport=await StdioTransport.start([str(paths.resources/'codex-cli/bin/codex'),'app-server','--listen','stdio://','-c','log_dir='+json.dumps(str(self.data/'logs'))],env=env,cwd=str(self.work))
        async def disconnected():
            self.emit('core/backendDisconnected',{'exitCode':self.app_transport.process.returncode})
            # Once RPC reading stops, keep stdout drained so normal EOF shutdown
            # cannot strand our owned CLI behind a full output pipe.
            async def discard_remaining():
                while await self.app_transport.reader.read(65536):pass
            self.backend_drain=asyncio.create_task(discard_remaining())
            for a in list(self.approvals.values()):
                self.expire_approval(a,'backend-disconnected')
        self.app=AppRpc(self.app_transport,requests=self.server_request,notifications=self.notification,disconnected=disconnected); self.app.core=self
        init=await self.app.request('initialize',{'clientInfo':{'name':'organic-core','version':'0.1'},'capabilities':{'experimentalApi':True}})
        await self.app.notify('initialized'); self.emit('core/initialized',init)
        # Discover official tool schemas once; per-thread REPLs are opened on demand.
        if paths.node.is_file() and paths.cua.is_file():
            catalog=await self.get_cua('_catalog'); tools=(await catalog.request('tools/list',{}))['tools']
            self.register_adapter(NS,'Official native CUA runtime. Follow returned documentation.',[{'type':'function','name':s['name'],'description':s['description'],'inputSchema':s['inputSchema']} for s in tools if s['name'] in ('js','js_reset')],self.cua_call)
            rpc,tr=self.cua.pop('_catalog'); await rpc.close()
        for module in getattr(self.args,'adapter',[]):
            await importlib.import_module(module).register(self)
        self.emit('core/adaptersReady',{'namespaces':list(self.adapters),'routes':[method+' '+path for method,path in self.routes]})
    async def interrupt(self,tid,turn):
        self.dead.add((tid,turn)); self.emit('core/turnRetired',{'threadId':tid,'turnId':turn})
        self.expire_approvals(tid,turn,'turn-interrupted')
        for p in list(self.inflight.values()):
            if p['threadId']==tid and p['turnId']==turn:
                await self.cua[tid][0].notify('notifications/cancelled',{'requestId':p['mcpRequestId'],'reason':'turn/interrupt'})
                self.emit('core/nativeCancelSent',p)
        for adapter in self.adapters.values():
            if adapter['interrupt']:await adapter['interrupt'](tid,turn)
        return await self.app.request('turn/interrupt',{'threadId':tid,'turnId':turn})
    async def rpc(self,method,p):
        p=copy.deepcopy(p)
        if method=='thread/start':
            p.setdefault('model',self.args.model); p.setdefault('modelProvider','openai'); p.setdefault('cwd',str(self.work))
            p.setdefault('approvalPolicy','untrusted'); p.setdefault('sandbox','workspace-write')
            p.setdefault('config',{'features.apps':True,'features.plugins':True}); p.setdefault('dynamicTools',self.spec)
            p['ephemeral']=False
            result=await self.app.request(method,p,timeout=60); tid=result['thread']['id']
            # Official metadata writes materialize a create-only rollout without
            # a synthetic turn. Replace the initial UI fallback on the first input.
            name=tid[-8:]
            await self.app.request('thread/name/set',{'threadId':tid,'name':name})
            result['thread']['name']=name
            # The backend owns path semantics (including a remote host's symlinks and drive names).
            # Save its canonical cwd so list/resume/start cannot create two project identities.
            cwd=result['thread'].get('cwd') or p['cwd']
            self.sessions[tid]={'id':tid,'cwd':cwd,'model':result.get('model'),'loaded':True,'active':None,'name':name,'autoName':True}; self.persist()
            return result
        if method=='turn/interrupt': return await self.interrupt(p['threadId'],p['turnId'])
        if method in ('turn/start','turn/steer'):
            tid=p['threadId']; s=self.sessions.get(tid)
            if not s: raise RpcFailure(-32602,'Use thread/resume before starting an existing thread')
            if not s.get('loaded'): await self.rpc('thread/resume',{'threadId':tid})
            if method=='turn/start' and s.get('autoName'):
                text=next((i.get('text','') for i in p.get('input',[]) if i.get('type')=='text' and i.get('text','').strip()),'')
                if text.lstrip().startswith('# Response annotations:'):
                    text=text.partition('</response-annotations>')[2].partition('## My request:')[2].strip()
                if text:
                    name=' '.join(text.split())[:80]
                    await self.app.request('thread/name/set',{'threadId':tid,'name':name})
                    s.update(name=name,autoName=False);self.persist()
        result=await self.app.request(method,p,timeout=90)
        if method in ('thread/resume','thread/read'):
            thread=result['thread']; tid=thread['id']; session=self.sessions.setdefault(tid,{'id':tid,'loaded':False})
            if thread.get('cwd'): session['cwd']=thread['cwd']
            if result.get('model'): session['model']=result['model']
            if method=='thread/resume': session['loaded']=True
            self.persist()
        if method=='thread/name/set' and p['threadId'] in self.sessions:
            self.sessions[p['threadId']].update(name=p['name'],autoName=False);self.persist()
        if method=='turn/start':
            tid=p['threadId']; turn=result['turn']; s=self.sessions[tid]
            if turn.get('status')=='inProgress' and not self.retired({'threadId':tid,'turnId':turn['id']}): s['active']=turn['id']; self.persist()
        return result
    def health(self):
        return {'name':'Organic Codex Core','version':'26102601','instanceId':self.instance_id,'dataDir':str(self.data),'workRoot':str(self.work),'pid':os.getpid(),'backendPid':self.app_transport.process.pid,'backendConnected':not self.app.closed,'lastEventId':self.log.last_id,'eventLog':self.log.stats(),'adapters':list(self.adapters),'modules':getattr(self.args,'adapter',[]),'routes':[method+' '+path for method,path in self.routes],'sessions':list(self.sessions.values()),'pendingApprovals':[x['public'] for x in self.approvals.values() if not x['future'].done()],'inflight':list(self.inflight.values()),'authorizationCount':len(self.authorizations.grants)}
    async def close(self):
        if self._closed:return
        self._closed=True;self.done.set()
        for approval in list(self.approvals.values()):self.expire_approval(approval,'core-shutdown')
        for tid,s in self.sessions.items():
            if self.app is not None and s.get('active'):
                try: await self.interrupt(tid,s['active'])
                except Exception as e: self.emit('core/shutdownError',{'error':str(e)})
        pending=list(self.app.server_tasks) if self.app is not None else []
        if pending: await asyncio.wait(pending,timeout=10)
        for rpc,tr in list(self.cua.values()):
            try:
                await rpc.close(); self.emit('core/cuaClosed',{'pid':tr.process.pid,'exitCode':tr.process.returncode})
            except Exception as e:self.emit('core/shutdownError',{'component':'cua','error':str(e)})
        for name,adapter in self.adapters.items():
            if adapter['close']:
                try:await adapter['close']()
                except Exception as e:self.emit('core/shutdownError',{'component':name,'error':str(e)})
        try:
            if self.app is not None:await self.app.close()
            elif self.app_transport is not None:await self.app_transport.close()
        except Exception as e:self.emit('core/shutdownError',{'component':'app-server','error':str(e)})
        finally:
            code=self.app_transport.process.returncode if self.app_transport is not None else None
            self.emit('core/closed',{'appServerExitCode':code,'processes':processes()})
            try:self.persist()
            finally:self.log.close()
    async def sse(self,writer,since,tid):
        writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n'); await writer.drain()
        while not self.done.is_set():
            changed=self.changed
            high=self.log.last_id
            for event in self.log.since(since,high):
                since=event['id']; p=event['params']
                if tid and (not isinstance(p,dict) or p.get('threadId')!=tid): continue
                writer.write(b'id: '+str(event['id']).encode()+b'\nevent: '+event['method'].encode()+b'\ndata: '+encode(event)+b'\n\n')
                await writer.drain()
            try: await asyncio.wait_for(changed.wait(),15)
            except asyncio.TimeoutError: writer.write(b': keepalive\n\n'); await writer.drain()
    async def event_json(self,writer,since,tid,limit=None):
        writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n')
        async def chunk(data):
            writer.write(('%x\r\n'%len(data)).encode()+data+b'\r\n');await writer.drain()
        await chunk(b'{"result":[');count=0
        for event in self.log.since(since):
            p=event['params']
            if tid and (not isinstance(p,dict) or p.get('threadId')!=tid):continue
            await chunk((b',' if count else b'')+encode(event));count+=1
            if limit and count>=limit:break
        await chunk(b']}');writer.write(b'0\r\n\r\n');await writer.drain()
    async def http(self,reader,writer):
        try:
            header=await reader.readuntil(b'\r\n\r\n'); lines=header.decode('latin1').split('\r\n'); verb,path,_=lines[0].split(' ')
            headers={k.lower():v.strip() for k,v in (s.split(':',1) for s in lines[1:] if ':' in s)}
            url=urlsplit(path); q=parse_qs(url.query)
            if url.path=='/events' and verb=='GET':
                await self.sse(writer,int(q.get('since',[headers.get('last-event-id','0')])[0]),q.get('threadId',[None])[0]); return
            size=int(headers.get('content-length','0')); body=json.loads((await reader.readexactly(size)).decode()) if size else {}
            if verb=='GET' and url.path=='/health': result=self.health()
            elif verb=='GET' and url.path=='/capabilities': result=capabilities(self)
            elif verb=='GET' and url.path=='/sessions': result=list(self.sessions.values())
            elif verb=='GET' and url.path=='/events.json':
                since=int(q.get('since',['0'])[0]); tid=q.get('threadId',[None])[0]
                await self.event_json(writer,since,tid,int(q['limit'][0]) if 'limit' in q else None);return
            elif verb=='GET' and url.path=='/authorizations':result=self.authorizations.grants
            elif verb=='POST' and url.path=='/authorizations':
                grant=self.authorizations.add(body['threadId'],body['app'],connector_id=body.get('connectorId','computer-use'),tools=body.get('tools'),origin='explicit-api')
                self.emit('core/authorizationGranted',{'threadId':body['threadId'],'grant':grant});result=grant
            elif verb=='DELETE' and url.path.startswith('/authorizations/'):
                identifier=url.path.split('/')[-1];result={'revoked':self.authorizations.revoke(identifier)};self.emit('core/authorizationRevoked',{'grantId':identifier})
            elif verb=='GET' and url.path.startswith('/images/'):
                file=paths.screenshots/pathlib.Path(url.path).name; payload=file.read_bytes()
                writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: '+(b'image/png' if file.suffix=='.png' else b'image/jpeg')+b'\r\nContent-Length: '+str(len(payload)).encode()+b'\r\nConnection: close\r\n\r\n'+payload); await writer.drain(); return
            elif verb=='POST' and url.path=='/rpc': result=await self.rpc(body['method'],body.get('params') or {})
            elif verb=='POST' and url.path.startswith('/approvals/'):
                aid=url.path.split('/')[-1]; self.approvals[aid]['future'].set_result(body); result={'responded':aid}
            elif verb=='POST' and url.path=='/shutdown': result={'shuttingDown':True}; self.done.set()
            elif (verb,url.path) in self.routes:result=await self.routes[(verb,url.path)](body,q)
            else: raise RpcFailure(-32601,'Unknown endpoint')
            payload=encode({'result':result}); writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: '+str(len(payload)).encode()+b'\r\nConnection: close\r\n\r\n'+payload); await writer.drain()
        except (ConnectionError,asyncio.IncompleteReadError): pass
        except Exception as e:
            payload=encode({'error':{'code':getattr(e,'code',-32603),'message':str(e),'data':getattr(e,'data',None)}})
            writer.write(b'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: '+str(len(payload)).encode()+b'\r\nConnection: close\r\n\r\n'+payload)
            try: await writer.drain()
            except ConnectionError: pass
        finally: writer.close()

async def serve(args):
    core=None
    async def dispatch(reader,writer):await core.http(reader,writer)
    # Reserve the port before touching the instance marker, event log or official
    # subprocesses. A second launch must not mutate the running instance's data.
    listener=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        listener.bind(('127.0.0.1',args.port));listener.listen(socket.SOMAXCONN)
        # Listen now, accept only after startup. Bind alone with SO_REUSEADDR is
        # not an exclusive reservation while two processes are still starting.
        server=await asyncio.start_server(dispatch,sock=listener,limit=16*1024*1024,start_serving=False)
    except BaseException:
        listener.close();raise
    installed=[]
    try:
        core=Core(args)
        for sig in (signal.SIGINT,signal.SIGTERM):
            asyncio.get_running_loop().add_signal_handler(sig,core.done.set);installed.append(sig)
        await core.start()
        await server.start_serving()
        core.emit('core/listening',{'host':'127.0.0.1','port':args.port});print(json.dumps(core.health()),flush=True)
        await core.done.wait()
    finally:
        server.close();await server.wait_closed()
        try:
            if core is not None:await core.close()
        finally:
            for sig in installed:asyncio.get_running_loop().remove_signal_handler(sig)

async def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',type=int,default=int(os.environ.get('ORGANIC_CORE_PORT','18793')))
    p.add_argument('--model',default='gpt-6.1-sol')
    p.add_argument('--proxy',default=os.environ.get('ORGANIC_CORE_PROXY'))
    p.add_argument('--data-dir',default=None)
    p.add_argument('--work-root',default=None)
    p.add_argument('--resources',default=None)
    p.add_argument('--allow-test-app',action='append',default=[])
    p.add_argument('--event-tail-count',type=int,default=128)
    p.add_argument('--event-tail-bytes',type=int,default=2*1024*1024)
    p.add_argument('--adapter',action='append',default=None)
    args=p.parse_args()
    if args.adapter is None: args.adapter=list(DEFAULT_MODULES)
    await serve(args)
if __name__=='__main__': asyncio.run(main())
