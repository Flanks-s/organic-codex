"""Shared artifact bytes and annotations; no frontend or new rendering engine."""
import base64,hashlib,json,mimetypes,pathlib,secrets,time

async def register(core):
    path=core.data/'preview.json'
    state=json.loads(path.read_text()) if path.exists() else {'artifacts':{},'annotations':[]}
    def persist():
        temp=path.with_suffix('.tmp');temp.write_text(json.dumps(state,ensure_ascii=False));temp.replace(path)
    async def add(body,query):
        file=pathlib.Path(body['path']).resolve()
        roots=[core.data,core.work]
        if body.get('threadId') in core.sessions:
            roots.append(pathlib.Path(core.sessions[body['threadId']]['cwd']).resolve())
        if not any(file==root or root in file.parents for root in roots):
            raise ValueError('Preview file must be inside the selected workspace or Core data directory')
        raw=file.read_bytes();digest=hashlib.sha256(raw).hexdigest();tid=body.get('threadId')
        identifier=hashlib.sha256((tid+'\0'+digest).encode()).hexdigest()[:20] if tid else digest[:20]
        folder=core.data/'preview-assets';folder.mkdir(exist_ok=True)
        snapshot=folder/(digest+file.suffix);snapshot.write_bytes(raw)
        item={'id':identifier,'path':str(snapshot),'sourcePath':str(file),'name':body.get('name',file.name),'mimeType':body.get('mimeType') or mimetypes.guess_type(file.name)[0] or 'application/octet-stream','bytes':len(raw),'sha256':digest,'threadId':tid,'createdAt':time.time()}
        state['artifacts'][identifier]=item;persist();core.emit('preview/artifactRegistered',item);return item
    async def artifacts(body,query):
        tid=query.get('threadId',[None])[0]
        return [a for a in state['artifacts'].values() if tid is None or a.get('threadId')==tid]
    async def content(body,query):
        item=state['artifacts'][query['id'][0]];raw=pathlib.Path(item['path']).read_bytes()
        return {**item,'dataBase64':base64.b64encode(raw).decode()}
    async def annotate(body,query):
        artifact=state['artifacts'][body['artifactId']]
        item={**body,'id':secrets.token_hex(10),'threadId':artifact.get('threadId'),'createdAt':time.time(),'artifactSha256':artifact['sha256']}
        state['annotations'].append(item);persist();core.emit('preview/annotationCreated',item);return item
    async def annotations(body,query):
        identifier=query.get('artifactId',[None])[0]
        return [a for a in state['annotations'] if identifier is None or a['artifactId']==identifier]
    async def remove(body,query):
        note=next(a for a in state['annotations'] if a['id']==body['id']);artifact=state['artifacts'][note['artifactId']]
        state['annotations']=[a for a in state['annotations'] if a['id']!=body['id']];persist();core.emit('preview/annotationDeleted',{'id':body['id'],'artifactId':note['artifactId'],'threadId':artifact.get('threadId')});return {'deleted':body['id']}
    async def attachment(body,query):
        raw=base64.b64decode(body['dataBase64']);folder=core.data/'attachments';folder.mkdir(exist_ok=True)
        name=pathlib.Path(body['name']).name;target=folder/(hashlib.sha256(raw).hexdigest()[:20]+'-'+name);target.write_bytes(raw)
        item=dict(await add({'path':str(target),'name':name,'mimeType':body.get('mimeType'),'threadId':body.get('threadId')},{}))
        if item['mimeType'].startswith('image/'):
            item['input']={'type':'image','url':'data:'+item['mimeType']+';base64,'+body['dataBase64']}
        else:item['input']={'type':'text','text':'User attached '+name+' at '+item['path']+' ('+item['mimeType']+'). Read this actual file when needed.'}
        core.emit('preview/attachmentUploaded',{'artifactId':item['id'],'threadId':body.get('threadId'),'name':name})
        return item
    for verb,url,handler in [('GET','/preview/artifacts',artifacts),('POST','/preview/artifacts',add),('GET','/preview/content',content),('GET','/preview/annotations',annotations),('POST','/preview/annotations',annotate),('POST','/preview/annotations/delete',remove),('POST','/attachments',attachment)]:core.register_route(verb,url,handler)
    core.emit('preview/ready',{'artifacts':len(state['artifacts']),'annotations':len(state['annotations'])})
