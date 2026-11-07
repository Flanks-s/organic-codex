"""Small macOS Appshots adapter: official window CUA + native display capture."""
import asyncio
import base64
import copy
import datetime
import hashlib
import json
import pathlib
import re
import uuid
from runtime_paths import paths

HERE = pathlib.Path(__file__).resolve().parent


async def native(*args):
    proc = await asyncio.create_subprocess_exec(str(paths.helpers/'CaptureHelper'), *map(str,args), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    stdout, stderr = await proc.communicate()
    value = json.loads(stdout) if stdout.strip() else {'success':False,'error':{'message':stderr.decode().strip(),'exitCode':proc.returncode}}
    return value

async def display_capture(folder):
    result_path = folder/'native-result.json'
    proc = await asyncio.create_subprocess_exec('/usr/bin/open','-W','-n',str(paths.helpers/'Organic Capture.app'),'--args','capture','screen',str(folder/'screen.png'),'--result-json',str(result_path),stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    stdout,stderr = await proc.communicate()
    if result_path.exists(): return json.loads(result_path.read_text())
    return {'success':False,'error':{'backend':'Organic Capture.app','message':stderr.decode().strip() or stdout.decode().strip(),'exitCode':proc.returncode}}

def image_item(image):
    data = pathlib.Path(image['path']).read_bytes()
    return {'type':'inputImage','imageUrl':'data:'+image['mimeType']+';base64,'+base64.b64encode(data).decode()}

async def frontmost_identity():
    """Discover the application identity without reading its accessibility body."""
    proc = await asyncio.create_subprocess_exec('/usr/bin/lsappinfo','front',stdout=asyncio.subprocess.PIPE)
    output,_ = await proc.communicate()
    asn = output.decode().strip()
    proc = await asyncio.create_subprocess_exec('/usr/bin/lsappinfo','info','-only','bundleid,name,pid,bundlepath',asn,stdout=asyncio.subprocess.PIPE)
    output,_ = await proc.communicate()
    fields = {}
    for key,value in re.findall(r'^"([^"]+)"=(.+)$',output.decode(),re.MULTILINE):
        fields[key] = json.loads(value)
    app = {'bundleId':fields.get('CFBundleIdentifier'),'name':fields.get('LSDisplayName'),'pid':fields.get('pid'),'path':fields.get('LSBundlePath')}
    return {'frontmostApplication':app,'captureApplication':app}

def client_context(core,tid):
    return {'threadId':tid,'turnId':core.sessions.get(tid,{}).get('active'),
            'callId':'capture-'+uuid.uuid4().hex,'_captureClientTarget':True}

def target_current(core,context):
    if not context: return True
    if core.retired(context): return False
    return not context.get('_captureClientTarget') or core.sessions.get(context['threadId'],{}).get('active') == context.get('turnId')

def stopped_capture():
    return {'success':False,'images':[],'delivery':{'submitted':False,'reason':'Capture target turn stopped or changed; no new turn was submitted.'}}

async def capture(core, body, context=None):
    if context is None and body.get('threadId'): context=client_context(core,body['threadId'])
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    capture_id = 'capture-' + uuid.uuid4().hex
    folder = core.data / 'captures' / capture_id
    folder.mkdir(parents=True)
    mode = body.get('mode','window')
    observation = await frontmost_identity() if mode=='window' else await native('inspect')
    bundle = {'id':capture_id,'threadId':body.get('threadId') or (context or {}).get('threadId'),'timeUTC':stamp,'mode':mode,'source':observation.get('captureApplication') or observation.get('frontmostApplication'),
              'clientRequestId':body.get('clientRequestId'),'destinationConversationId':body.get('destinationConversationId'),
              'frontmostApplication':observation.get('frontmostApplication'), 'requestedApp':body.get('app'),
              'window':observation.get('focusedWindow'), 'windows':observation.get('applicationWindows',[]),
              'images':[],'errors':[], 'permissions':{'screenCaptureAccess':observation.get('screenCaptureAccess'),'accessibilityTrusted':observation.get('accessibilityTrusted')}}
    text_path = folder / 'accessibility.txt'
    text_path.write_text((observation.get('focusedWindow') or {}).get('text',''), encoding='utf-8')
    bundle['text'] = {'path':str(text_path),'mimeType':'text/plain','source':'native-AX'}
    if not target_current(core,context): return stopped_capture()
    if mode == 'screen':
        result = await display_capture(folder)
        bundle['captureBackendPermissions']={'screenCaptureAccess':result.get('screenCaptureAccess'),'accessibilityTrusted':result.get('accessibilityTrusted')}
        (folder/'native-result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
        if result.get('success'):
            bundle['images'].append(result['image'])
        else:
            bundle['errors'].append({'backend':'ScreenCaptureKit',**result.get('error',{})})
    elif mode == 'window':
        tid = (context or {}).get('threadId') or body.get('threadId')
        if not tid:
            bundle['errors'].append({'message':'Window CUA capture requires threadId to route the original application approval.'})
        else:
            app = body.get('app') or (bundle['source'] or {}).get('bundleId')
            if not app:
                bundle['errors'].append({'message':'No frontmost application is available.'})
            else:
                p = dict(context or {'threadId':tid,'turnId':core.sessions.get(tid,{}).get('active'),'callId':capture_id})
                local = {'params':{**p,'namespace':'organic_cua','tool':'js'}}
                if context and '_meta' in context: local['_meta'] = copy.deepcopy(context['_meta'])
                name = 'organicCapture_' + capture_id.replace('-','_')
                codes = ['var '+name+' = await cua.getApp('+json.dumps(app)+');', 'await '+name+'.getAXStateAndScreenshot({disableDiffing:true});']
                last = None
                for code in codes:
                    if not target_current(core,context): return stopped_capture()
                    local['params']['arguments'] = {'code':code,'title':'Capture application window and accessibility text'}
                    last = await core.cua_call(local)
                    if not last.get('success'): break
                cua_text_blocks = []
                approved_items = (last or {}).get('contentItems',[]) if (last or {}).get('success') else []
                for index,item in enumerate(approved_items):
                    if item.get('type') in ('inputText','text') and item.get('text'):
                        cua_text_blocks.append(item['text'])
                    if item.get('type') == 'inputImage':
                        header,data = item['imageUrl'].split(',',1)
                        mime = header[5:].split(';')[0]
                        path = folder/('window-'+str(index)+('.png' if mime=='image/png' else '.jpg'))
                        path.write_bytes(base64.b64decode(data))
                        bundle['images'].append({'path':str(path),'mimeType':mime})
                if (last or {}).get('success') and cua_text_blocks:
                    official_text = '\n\n'.join(cua_text_blocks)
                    official_path = folder/'official-cua-accessibility.txt'
                    official_path.write_text(official_text,encoding='utf-8')
                    bundle['text']['officialCuaPath'] = str(official_path)
                    if not text_path.read_text(encoding='utf-8').strip():
                        text_path.write_text(official_text,encoding='utf-8')
                        bundle['text']['source'] = 'official-cua'
                if not (last or {}).get('success'):
                    bundle['errors'].append({'backend':'official-cua','result':last})
                elif target_current(core,context):
                    observed = await native('inspect',app)
                    bundle['source']=observed.get('captureApplication') or bundle['source']
                    bundle['window']={k:v for k,v in (observed.get('focusedWindow') or {}).items() if k!='text'}
                    bundle['windows']=observed.get('applicationWindows',[])
    else:
        raise ValueError('mode must be screen or window')
    for image in bundle['images']:
        data=pathlib.Path(image['path']).read_bytes()
        image.update(bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    bundle['text']['content'] = text_path.read_text(encoding='utf-8')
    bundle['success'] = bool(bundle['images'])
    bundle['manifestPath'] = str(folder/'attachment.json')
    pathlib.Path(bundle['manifestPath']).write_text(json.dumps(bundle,ensure_ascii=False,indent=2),encoding='utf-8')
    core.emit('core/captureReady',bundle)
    return bundle

async def register(core):
    hotkeys=None
    def hotkey_service():
        nonlocal hotkeys
        if hotkeys is None:
            from .hotkey_service import HotkeyService
            hotkeys=HotkeyService(core,HERE)
        return hotkeys
    async def close():
        if hotkeys is not None:await hotkeys.close()
    async def call(msg):
        p = msg['params']
        context = copy.deepcopy(p)
        if '_meta' in msg: context['_meta']=copy.deepcopy(msg['_meta'])
        result = await capture(core,p['arguments'],context)
        items = [{'type':'inputText','text':json.dumps(result,ensure_ascii=False)}]
        items.extend(image_item(x) for x in result.get('images',[]))
        return {'success':result.get('success',False),'contentItems':items}
    core.register_adapter('organic_capture','Capture a frontmost macOS application window, accessibility text, or full display. Window mode reuses official CUA approvals; screen mode uses ScreenCaptureKit.',[
        {'type':'function','name':'capture','description':'Capture current frontmost app (window) or composited main display (screen), returning real image bytes and source metadata.',
         'inputSchema':{'type':'object','properties':{'mode':{'type':'string','enum':['window','screen']},'app':{'type':'string','description':'Optional application bundle id or path for window capture.'}}}}
    ],call,close=close)
    async def inspect_route(body,query): return await frontmost_identity()
    async def capture_route(body,query):
        try:
            result = await capture(core,body)
        except Exception as error:
            core.emit('core/captureFailed',{'clientRequestId':body.get('clientRequestId'),'threadId':body.get('threadId'),'message':str(error)})
            raise
        result.setdefault('clientRequestId',body.get('clientRequestId'))
        result.setdefault('threadId',body.get('threadId'))
        if not result.get('id'):
            core.emit('core/captureFailed',{**result,'message':'Capture stopped or its target changed.'})
        if body.get('includeImages',True): result['contentItems']=[image_item(x) for x in result.get('images',[])]
        return result
    async def capture_result(body,query):
        identifier=(query.get('id') or [''])[0]
        request_id=(query.get('clientRequestId') or [''])[0]
        folder=core.data/'captures'
        if identifier:
            if not re.fullmatch(r'capture-[0-9a-f]{32}',identifier): raise ValueError('Invalid capture id')
            manifest=folder/identifier/'attachment.json'
            result=json.loads(manifest.read_text())
        elif request_id and len(request_id)<=128:
            result=None
            # Only explicit recovery reads old manifests; no background capture or repeated POST.
            for manifest in sorted(folder.glob('capture-*/attachment.json'),key=lambda p:p.stat().st_mtime,reverse=True)[:256]:
                candidate=json.loads(manifest.read_text())
                if candidate.get('clientRequestId')==request_id:
                    result=candidate;break
            if result is None:return {'pending':True,'clientRequestId':request_id}
        else: raise ValueError('Provide capture id or clientRequestId')
        result['contentItems']=[image_item(x) for x in result.get('images',[])]
        return result
    async def send_route(body,query):
        tid=body['threadId']
        context=client_context(core,tid)
        result = await capture(core,body,context)
        if not result.get('success'): return result
        if not target_current(core,context):
            result['delivery']={'submitted':False,'reason':'Capture target turn stopped or changed; attachment was not submitted.'}
            return result
        text=body.get('text','Attached Appshot: screenshot and accessibility text from the target machine.')
        text+='\n'+json.dumps(result,ensure_ascii=False)+'\n'+pathlib.Path(result['text']['path']).read_text()
        inputs=[{'type':'text','text':text}]
        inputs.extend({'type':'image','url':image_item(x)['imageUrl']} for x in result['images'])
        active=context['turnId']
        method='turn/steer' if active else 'turn/start'
        params={'threadId':tid,'input':inputs}
        if active: params['expectedTurnId']=active
        result['delivery']={'method':method,'result':await core.rpc(method,params)}
        return result
    core.register_route('GET','/capture/frontmost',inspect_route)
    core.register_route('POST','/capture',capture_route)
    core.register_route('GET','/capture/result',capture_result)
    core.register_route('POST','/capture/send',send_route)
    async def hotkey_status(body,query):return hotkey_service().status()
    async def hotkey_configure(body,query):return await hotkey_service().configure(body)
    core.register_route('GET','/capture/hotkey',hotkey_status)
    core.register_route('POST','/capture/hotkey',hotkey_configure)
