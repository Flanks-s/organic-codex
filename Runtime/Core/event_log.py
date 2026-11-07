"""Append-only events with a byte/count bounded raw tail and streaming disk replay."""
import collections,json,os

class EventLog:
    def __init__(self,path,max_events=128,max_bytes=2*1024*1024):
        self.path=path; self.max_events=max_events; self.max_bytes=max_bytes
        self.tail=collections.deque(); self.tail_bytes=0; self.last_id=0
        self.disk_replays=0; self.tail_replays=0
        if path.exists():
            with path.open('rb') as source:
                for raw in source:
                    identifier=json.loads(raw)['id']; self.last_id=identifier; self._retain(identifier,raw)
        self.writer=path.open('ab'); os.chmod(path,0o600)
    def _retain(self,identifier,raw):
        self.tail.append((identifier,raw)); self.tail_bytes+=len(raw)
        while len(self.tail)>self.max_events or self.tail_bytes>self.max_bytes:
            _,evicted=self.tail.popleft(); self.tail_bytes-=len(evicted)
    def append(self,event):
        self.last_id+=1; event={'id':self.last_id,**event}
        raw=json.dumps(event,ensure_ascii=False,separators=(',',':')).encode()+b'\n'
        self.writer.write(raw); self.writer.flush(); self._retain(self.last_id,raw)
        return event
    def since(self,cursor,up_to=None):
        high=self.last_id if up_to is None else up_to
        if cursor>=high:return
        if self.tail and cursor>=self.tail[0][0]-1:
            self.tail_replays+=1
            # Copy only the bounded tail: a yielding HTTP consumer may append events.
            for identifier,raw in tuple(self.tail):
                if cursor<identifier<=high:yield json.loads(raw)
            return
        self.disk_replays+=1
        with self.path.open('rb') as source:
            for raw in source:
                event=json.loads(raw)
                if event['id']>high:break
                if event['id']>cursor:yield event
    def stats(self):
        return {'lastEventId':self.last_id,'tailEvents':len(self.tail),'tailBytes':self.tail_bytes,'maxTailEvents':self.max_events,'maxTailBytes':self.max_bytes,'diskBytes':self.path.stat().st_size,'diskReplays':self.disk_replays,'tailReplays':self.tail_replays}
    def close(self):self.writer.close()
