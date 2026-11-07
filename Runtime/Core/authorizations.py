"""Conversation-scoped app grants learned only from explicit session approvals."""
import copy,json,os,secrets,time

class SessionAuthorizations:
    def __init__(self,path):
        self.path=path; self.exists=path.exists()
        self.grants=json.loads(path.read_text()) if self.exists else []
    def persist(self):
        temp=self.path.with_suffix('.tmp'); temp.write_text(json.dumps(self.grants,ensure_ascii=False,indent=2));os.chmod(temp,0o600);temp.replace(self.path)
    def scope(self,msg,source):
        if source!='cua' or msg.get('method')!='elicitation/create':return None
        meta=(msg.get('params') or {}).get('_meta') or {}; app=(meta.get('tool_params') or {}).get('app')
        if meta.get('connector_id')!='computer-use' or not app:return None
        return {'source':source,'connectorId':meta['connector_id'],'app':app,'tool':meta.get('tool_name')}
    def matching(self,tid,msg,source):
        scope=self.scope(msg,source)
        if not scope:return None
        return next((g for g in self.grants if g['threadId']==tid and all(g[k]==scope[k] for k in ('source','connectorId','app')) and (not g.get('tools') or scope['tool'] in g['tools'])),None)
    def add(self,tid,app,*,connector_id='computer-use',tools=None,response=None,origin=None):
        response=response or {'action':'accept','content':{},'_meta':{'persist':'session'}}
        grant={'id':secrets.token_hex(8),'threadId':tid,'scope':'app','source':'cua','connectorId':connector_id,'app':app,'tools':tools or [],'response':copy.deepcopy(response),'approvedAt':time.time(),'origin':origin}
        self.grants=[g for g in self.grants if not all(g[k]==grant[k] for k in ('threadId','source','connectorId','app','tools'))]+[grant]
        self.persist();return grant
    def learn(self,public,response,*,persist=True):
        scope=self.scope(public['request'],public['source'])
        if not scope or response.get('action')!='accept' or (response.get('_meta') or {}).get('persist')!='session':return None
        existing=self.matching(public['threadId'],public['request'],public['source'])
        if existing:return existing
        return self.add(public['threadId'],scope['app'],response=response,origin=public.get('approvalId'))
    def revoke(self,identifier):
        before=len(self.grants);self.grants=[g for g in self.grants if g['id']!=identifier];self.persist();return len(self.grants)<before
