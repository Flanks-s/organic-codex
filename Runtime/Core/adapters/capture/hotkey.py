"""Run an explicit global Appshot shortcut, sending into one selected conversation."""
import argparse, json, pathlib, subprocess, urllib.request

def main():
    p=argparse.ArgumentParser()
    p.add_argument('--endpoint',default='http://127.0.0.1:18793')
    p.add_argument('--thread',required=True)
    p.add_argument('--helper',required=True)
    p.add_argument('--mode',choices=['window','screen'],default='window')
    p.add_argument('--probe',action='store_true')
    a=p.parse_args()
    folder=pathlib.Path(__file__).resolve().parent
    helper=pathlib.Path(a.helper)
    proc=subprocess.Popen([str(helper),*(['hotkey-probe'] if a.probe else [])],stdout=subprocess.PIPE,text=True)
    buffer=''
    try:
        for line in proc.stdout:
            buffer+=line
            try: event=json.loads(buffer)
            except json.JSONDecodeError: continue
            buffer='';print(json.dumps(event),flush=True)
            if event.get('event')=='captureRequested':
                req=urllib.request.Request(a.endpoint+'/capture/send',data=json.dumps({'threadId':a.thread,'mode':a.mode}).encode(),headers={'Content-Type':'application/json'})
                with urllib.request.urlopen(req,timeout=180) as response: print(response.read().decode(),flush=True)
    except KeyboardInterrupt: pass
    finally:
        if proc.poll() is None: proc.terminate()
        proc.wait()
if __name__=='__main__':main()
