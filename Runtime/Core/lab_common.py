import sys
sys.dont_write_bytecode=True
import asyncio,base64,copy,datetime,hashlib,json,os,pathlib,re,subprocess
from transport import RpcClient,StdioTransport,RpcFailure
P=pathlib.Path;ROOT=P(__file__).resolve().parent
from runtime_paths import paths
BUNDLE='org.organiccodex.research.gui.r03';TARGET=str(paths.work/'Organic GUI Probe.app')
def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def save(path,value):
    p=paths.data/path;p.write_text(json.dumps(value,ensure_ascii=False,indent=2));p.chmod(0o600)
def journal(path,kind,**data):
    p=paths.data/path
    with p.open('a') as f:f.write(json.dumps({'timeUTC':now(),'kind':kind,**data},ensure_ascii=False)+'\n');f.flush()
    p.chmod(0o600)
def processes():
    p=subprocess.run(['/bin/ps','-ww','-axo','pid=,ppid=,lstart=,comm='],capture_output=True,text=True,timeout=5)
    if p.returncode:raise RuntimeError('ps failed: '+p.stderr)
    rows=[x for x in p.stdout.splitlines() if re.search(r'ChatGPT|Electron|Organic|SkyComputer|node_repl|cua_node|CodexCLI|GuiProbe',x,re.I)]
    return {'timeUTC':now(),'rows':rows,'electronMainAbsent':not any(re.search(r'/Contents/MacOS/(?:ChatGPT|BetterCodexOrganic|Electron)(?:\s|$)',x) or 'Electron Framework' in x for x in rows)}
def environment(network=False):
    e={k:v for k,v in os.environ.items() if not k.startswith(('CODEX_','NODE_REPL_','CUA_REPL_','SKY_','OPENAI_','ANTHROPIC_')) and k not in ('NODE_OPTIONS','NODE_PATH','ELECTRON_RUN_AS_NODE')}
    e.update({'CODEX_HOME':str(P.home()/'.codex'),'CODEX_CLI_PATH':str(paths.resources/'codex-cli/bin/codex'),'NODE_REPL_NODE_PATH':str(paths.resources/'cua_node/bin/node'),'CUA_REPL_NODE_REPL_PATH':str(paths.resources/'cua_node/bin/node_repl'),'NODE_REPL_NODE_MODULE_DIRS':str(paths.modules),'NODE_REPL_TRUSTED_CODE_PATHS':str(paths.modules),'CUA_REPL_ENABLED_SURFACES':'computer','SKY_CUA_SERVICE_PATH':str(P.home()/'.codex/computer-use/Codex Computer Use.app')})
    e.update(paths.child_environment())
    return e
async def original_approval(msg,record,active=True):
    record('originalApprovalRequest',request=msg)
    if msg.get('method')!='elicitation/create':raise RpcFailure(-32601,'No lab adapter for '+str(msg.get('method')))
    p=msg.get('params') or {};meta=p.get('_meta') or {};app=(meta.get('tool_params') or {}).get('app')
    allowed=active and meta.get('connector_id')=='computer-use' and app in (BUNDLE,TARGET)
    response={'action':'accept','content':{},'_meta':{'persist':'session'}} if allowed else {'action':'decline','content':None}
    record('originalApprovalResponse',requestId=msg.get('id'),response=response,authorizedTestApp=allowed)
    return response
async def start_mcp(record,approval_active=lambda:True):
    async def callback(msg):return await original_approval(msg,record,approval_active())
    transport=await StdioTransport.start([str(paths.resources/'cua_node/bin/node'),str(paths.modules/'@oai/cua-repl/bin/cua-repl.mjs')],env=environment(),cwd=str(paths.work))
    client=RpcClient(transport,requests=callback,jsonrpc=True)
    await client.request('initialize',{'protocolVersion':'2025-06-18','capabilities':{'elicitation':{'form':{}}},'clientInfo':{'name':'organic-isolated-gui-test','version':'0.0.3'}})
    await client.notify('notifications/initialized')
    return client,transport
def convert_result(raw,call_id):
    items=[];images=[];evidence=copy.deepcopy(raw)
    for i,block in enumerate(raw.get('content',[])):
        kind=block.get('type')
        if kind=='text':items.append({'type':'inputText','text':block['text']})
        elif kind=='image':
            data=base64.b64decode(block['data'],validate=True);mime=block['mimeType']
            folder=paths.screenshots;folder.mkdir(exist_ok=True)
            file=folder/(re.sub(r'[^a-zA-Z0-9_-]','_',call_id)+'-'+str(i)+('.png' if mime=='image/png' else '.jpg'))
            file.write_bytes(data);file.chmod(0o600)
            receipt={'path':str(file),'mimeType':mime,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
            evidence['content'][i].pop('data');evidence['content'][i]['savedImage']=receipt;images.append(receipt)
            items.append({'type':'inputImage','imageUrl':'data:'+mime+';base64,'+block['data']})
        elif kind=='audio':items.append({'type':'inputAudio','audioUrl':'data:'+block['mimeType']+';base64,'+block['data']})
        else:items.append({'type':'inputText','text':json.dumps(block,ensure_ascii=False)})
    return {'success':raw.get('isError') is not True,'contentItems':items},evidence,images
