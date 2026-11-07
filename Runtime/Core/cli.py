"""Small HTTP client; task lifetime belongs to the core."""
import argparse,json,pathlib,sys,urllib.request
def request(base,path,body=None):
    req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers={'Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(req,timeout=120) as r: return json.load(r)
    except urllib.error.HTTPError as e: return json.load(e)
def main():
    p=argparse.ArgumentParser(); p.add_argument('--url',default='http://127.0.0.1:18793'); p.add_argument('command',choices=['health','rpc','events','shutdown']); p.add_argument('argument',nargs='?'); args=p.parse_args()
    if args.command=='events':
        with urllib.request.urlopen(args.url+'/events?since='+(args.argument or '0'),timeout=120) as r:
            for line in r: print(line.decode().rstrip(),flush=True)
        return
    if args.command=='rpc':
        value=json.loads(pathlib.Path(args.argument[1:]).read_text()) if args.argument.startswith('@') else json.loads(args.argument)
        result=request(args.url,'/rpc',value)
    else: result=request(args.url,'/'+args.command,{} if args.command=='shutdown' else None)
    print(json.dumps(result,ensure_ascii=False,indent=2))
if __name__=='__main__':main()
