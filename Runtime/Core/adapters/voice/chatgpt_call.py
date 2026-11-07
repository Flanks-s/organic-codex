"""Create the same client-owned call as the installed official frontend.

Credentials stay inside the MBA child process. Only an SDP answer and call ID
return to the local controller. No auth value is put in a command or artifact.
"""
import base64
import json
from runtime_paths import paths


def call_request(thread_id, offer_sdp, version="v3", voice=None):
    """Build a normal App Server command, containing no credential values."""
    payload = {"threadId": thread_id, "sdp": offer_sdp, "version": version, "voice": voice}
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    script = r'''
import base64,hashlib,json,pathlib,urllib.request,urllib.error
request_data=json.loads(base64.b64decode(PAYLOAD))
credentials=json.loads((pathlib.Path.home()/'.codex'/'auth.json').read_text())
tokens=credentials.get('tokens') or {}
access=tokens.get('access_token')
if not access:
    print(json.dumps({'error':'No current OAuth access token in the configured file credential store'}))
    raise SystemExit(1)
v3=request_data['version']=='v3'
audio={'output':{'voice':request_data.get('voice') or ('marin' if v3 else 'cove')}}
session=({'audio':audio,'delegation':{'type':'client'},'model':'gpt-live-1-codex'} if v3 else {'audio':{**audio,'input':{'format':{'type':'audio/pcm','rate':24000}}},'model':'gpt-realtime-1.5','type':'quicksilver'})
if request_data['version']=='v2':session.pop('model',None)
headers={'Authorization':'Bearer '+access,'Content-Type':'application/json','OpenAI-Alpha':'quicksilver=v2' if request_data['version'] in ('v2','v3') else 'quicksilver=v1','Thread-Id':request_data['threadId'],'Session-Id':request_data['threadId'],'User-Agent':'organic-core/0.1'}
if tokens.get('account_id'):headers['ChatGPT-Account-Id']=tokens['account_id']
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None
opener=urllib.request.build_opener(NoRedirect)
outgoing=json.dumps({'sdp':request_data['sdp'],'session':session}).encode()
request=urllib.request.Request('https://chatgpt.com/backend-api/wham/realtime/calls?intent=quicksilver&architecture=avas',data=outgoing,headers=headers,method='POST')
try:
    response=opener.open(request,timeout=60)
except urllib.error.HTTPError as error:
    response=error
with response:
    body=response.read().decode('utf-8','replace')
    location=response.headers.get('location','')
    sent_session=json.loads(outgoing)['session']
    print(json.dumps({'status':response.status,'answerSdp':body if response.status<300 else None,'callId':location.split('?')[0].rstrip('/').split('/')[-1] if location else None,'errorBody':body if response.status>=300 else None,'requestSessionKeys':sorted(sent_session),'requestSessionHasModel':'model' in sent_session,'requestBodySha256':hashlib.sha256(outgoing).hexdigest(),'requestVersion':request_data['version'],'requestAlpha':headers['OpenAI-Alpha']}))
'''.replace("PAYLOAD", repr(encoded))
    return {"command": ["/usr/bin/python3", "-c", script],
            "cwd": str(paths.work), "timeoutMs": 70000,
            "outputBytesCap": 256000}


def call_result(result, diagnostics=False):
    """Preserve actual upstream errors; expose no transport diagnostics on success."""
    if result["exitCode"]:
        return {"error": {"message": result["stdout"] or result["stderr"]}}
    response = json.loads(result["stdout"])
    if diagnostics:
        return response
    return {key: response.get(key) for key in ("status", "answerSdp", "callId", "errorBody")} if "status" in response else response


def create_call(client, thread_id, offer_sdp, version="v3", voice=None, diagnostics=False):
    response = client.rpc("command/exec", **call_request(thread_id, offer_sdp, version, voice))
    if "error" in response:
        return response
    return call_result(response["result"], diagnostics=diagnostics)


async def create_call_on_core(core, thread_id, offer_sdp, version="v3", voice=None):
    # Await the existing async RPC directly: a synchronous HTTP request back to
    # the same Core would block its event loop and deadlock the new HTTP route.
    result = call_result(await core.rpc("command/exec", call_request(thread_id, offer_sdp, version, voice)))
    if "error" in result:
        from transport import RpcFailure
        error = result["error"]
        raise RpcFailure(-32000, error.get("message", str(error)) if isinstance(error, dict) else str(error))
    return result


if __name__ == "__main__":
    import argparse
    import pathlib
    from voice import VoiceClient
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("thread")
    parser.add_argument("offer")
    parser.add_argument("--version", default="v3", choices=["v1", "v2", "v3"])
    parser.add_argument("--out", default="call-result.json")
    args = parser.parse_args()
    result = create_call(VoiceClient(), args.thread, pathlib.Path(args.offer).read_text(), args.version)
    pathlib.Path(args.out).write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "answerSdp"}, ensure_ascii=False))
