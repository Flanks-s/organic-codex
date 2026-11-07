"""Thin dynamic-tools registration; Core retains the App Server model/tool loop."""
import asyncio, base64, copy, datetime, hashlib, json, pathlib
from lab_common import environment, convert_result
from runtime_paths import paths
from transport import RpcClient, StdioTransport, RpcFailure

ROOT=pathlib.Path(__file__).resolve().parent

async def register(core):
    standalone=None
    standalone_lock=asyncio.Lock()
    official={}
    official_locks={}
    official_context={}
    official_inflight={}

    async def ensure_standalone(thread_id=None):
        nonlocal standalone
        if standalone is None:
            env=environment();env['ORGANIC_BROWSER_PROXY']=core.args.proxy or ''
            tr=await StdioTransport.start([str(paths.resources/'cua_node/bin/node'),str(ROOT/'runtime.mjs')],env=env,cwd=str(core.work))
            standalone=(RpcClient(tr),tr)
            core.emit('browser/runtimeStarted',{'threadId':thread_id,'pid':tr.process.pid,'backend':'independent-chromium'})
        return standalone[0]

    async def standalone_call(msg):
        nonlocal standalone
        p=msg['params']
        async with standalone_lock:
            if core.retired(p): raise RuntimeError('Turn retired before browser dispatch')
            await ensure_standalone(p['threadId'])
            if core.retired(p): raise RuntimeError('Turn retired while browser initialized')
            result=await standalone[0].request('browser',p['arguments'],timeout=45)
            if 'data' in result:
                raw={'content':[{'type':'image','mimeType':result['mimeType'],'data':result['data']}]}
            else: raw={'content':[{'type':'text','text':json.dumps(result,ensure_ascii=False)}]}
            reply,evidence,images=convert_result(raw,p['callId'])
            core.emit('browser/result',{'threadId':p['threadId'],'turnId':p['turnId'],'callId':p['callId'],'backend':'independent-chromium','result':evidence,'images':images})
            return reply

    async def official_call(msg):
        p=msg['params'];tid=p['threadId']
        async with official_locks.setdefault(tid,asyncio.Lock()):
            official_context[tid]=p
            if core.retired(p): raise RuntimeError('Turn retired before official browser dispatch')
            if tid not in official:
                async def approval(request): return await core.approval(request,'browser',tid,official_context[tid])
                env=environment();env['CUA_REPL_ENABLED_SURFACES']='browser';env['CUA_REPL_BROWSER_ENV']='codex-app'
                tr=await StdioTransport.start([str(paths.resources/'cua_node/bin/node'),str(paths.modules/'@oai/cua-repl/bin/cua-repl.mjs')],env=env,cwd=str(core.work))
                rpc=RpcClient(tr,requests=approval,jsonrpc=True)
                await rpc.request('initialize',{'protocolVersion':'2025-06-18','capabilities':{'elicitation':{'form':{}}},'clientInfo':{'name':'organic-official-browser-adapter','version':'0.1'}})
                await rpc.notify('notifications/initialized');official[tid]=(rpc,tr)
            params={'name':p['tool'],'arguments':copy.deepcopy(p['arguments'])}
            original_meta=msg.get('_meta') or p.get('_meta') or {}
            meta=copy.deepcopy(original_meta)
            original_turn_meta=meta.get('x-codex-turn-metadata')
            turn_meta=json.loads(original_turn_meta) if isinstance(original_turn_meta,str) else copy.deepcopy(original_turn_meta or {})
            missing={key:value for key,value in (('session_id',tid),('turn_id',p['turnId'])) if key not in turn_meta}
            if missing:
                turn_meta.update(missing)
                meta['x-codex-turn-metadata']=json.dumps(turn_meta,separators=(',',':')) if isinstance(original_turn_meta,str) else turn_meta
                core.emit('browser/officialMetadataBound',{'threadId':tid,'turnId':p['turnId'],'originalMetaKeys':list(original_meta),'addedFields':list(missing),'source':'real item/tool/call threadId and turnId'})
            params['_meta']=meta
            if core.retired(p): raise RuntimeError('Turn retired while official browser initialized')
            rpc=official[tid][0]
            official_inflight[tid]={'turnId':p['turnId'],'requestId':'organic-'+str(rpc.sequence+1)}
            try:raw=await rpc.request('tools/call',params,timeout=180)
            finally:official_inflight.pop(tid,None)
            reply,evidence,images=convert_result(raw,p['callId'])
            core.emit('browser/result',{'threadId':tid,'turnId':p['turnId'],'callId':p['callId'],'backend':'official-extension-provider','result':evidence,'images':images})
            return reply

    async def close_standalone():
        if standalone:await standalone[0].close()

    async def browser_tabs(body,query):
        async with standalone_lock:
            if standalone is None:
                return {'backend':'independent-chromium','runtime':'existing-playwright-1.57.0','tabs':[]}
            return await standalone[0].request('browser',{'action':'tabs'},timeout=45)

    async def browser_screenshot(body,query):
        async with standalone_lock:
            if standalone is None:
                raise RpcFailure(-32004,'Owned browser runtime has not started')
            result=await standalone[0].request('browser',{'action':'screenshot','tabId':body['tabId']},timeout=45)
            data=base64.b64decode(result['data'])
            metadata={k:result[k] for k in ('tabId','url','title','width','height')}
            metadata.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),capturedAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
            return {'tabId':result['tabId'],'mimeType':result['mimeType'],'data':result['data'],'metadata':metadata}

    async def close_official():
        for rpc,tr in official.values():await rpc.close()
    async def interrupt_official(tid,turn):
        current=official_inflight.get(tid)
        if current and current['turnId']==turn:
            await official[tid][0].notify('notifications/cancelled',{'requestId':current['requestId'],'reason':'turn/interrupt'})

    schema={'type':'object','properties':{
        'action':{'type':'string','enum':['discover','new','snapshot','fill','click','screenshot','close']},
        'tabId':{'type':'string'},'url':{'type':'string'},'selector':{'type':'string'},'value':{'type':'string'}
    },'required':['action'],'additionalProperties':False}
    core.register_adapter('organic_browser','Existing independent Chromium via Playwright. Use new with a URL to open an owned page, read DOM and controls, fill/click grounded selectors, then screenshot. Respect actual browser and website access restrictions. No Electron.',[
        {'type':'function','name':'browser','description':'Discover or operate owned independent browser tabs. new accepts a URL; omitting it opens a blank page. Use DOM/controls returned by new/snapshot for selectors. screenshot returns a real image.','inputSchema':schema}
    ],standalone_call,close=close_standalone)
    core.register_route('GET','/browser/tabs',browser_tabs)
    core.register_route('POST','/browser/screenshot',browser_screenshot)
    for route,action in (('open','new'),('close','close'),('snapshot','snapshot')):
        async def endpoint(body,query,action=action):
            async with standalone_lock:
                if action=='new':
                    from urllib.parse import urlsplit
                    if urlsplit(body.get('url','')).scheme not in ('http','https','about'):
                        raise RpcFailure(-32602,'Browser URL must use http, https or about')
                    rpc=await ensure_standalone(body.get('threadId'))
                    params={'action':action,'url':body['url']}
                else:
                    if standalone is None:raise RpcFailure(-32004,'Owned browser runtime has not started')
                    rpc=standalone[0];params={'action':action,'tabId':body['tabId']}
                return await rpc.request('browser',params,timeout=45)
        core.register_route('POST','/browser/'+route,endpoint)
    # Read the official descriptions/schema without starting a persistent browser.
    catalog=json.loads((ROOT/'official-tools.json').read_text())['tools']
    core.register_adapter('organic_browser_official','Official installed browser extension provider. Follow returned cua documentation. Original permissions and turn metadata are forwarded.',[
        {'type':'function','name':s['name'],'description':s['description'],'inputSchema':s['inputSchema']}
        for s in catalog if s['name'] in ('js','js_reset')
    ],official_call,close=close_official,interrupt=interrupt_official)
