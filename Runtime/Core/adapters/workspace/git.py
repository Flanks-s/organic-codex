"""Selected-file Git actions, using argv and content checks before mutation."""
import asyncio
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
from transport import RpcFailure

GIT = shutil.which('git')
DIFF_LIMIT = 2 * 1024 * 1024


def directory(value):
    if not isinstance(value, str) or not Path(value).is_absolute():
        raise RpcFailure(-32602, 'cwd must be an absolute existing directory')
    path = Path(value).resolve()
    if not path.is_dir(): raise RpcFailure(-32602, 'cwd is not a directory')
    return path


class GitWorkspace:
    def __init__(self): self.locks = {}

    async def run(self, cwd, *args, allowed=(0,)):
        if not GIT: raise RpcFailure(-32004, 'Git executable is unavailable')
        env = {**os.environ, 'GIT_TERMINAL_PROMPT':'0', 'GIT_PAGER':'cat', 'LC_ALL':'C', 'GIT_LITERAL_PATHSPECS':'1'}
        process = await asyncio.create_subprocess_exec(GIT, '-C', str(cwd), *args,
                    stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env)
        try: stdout, stderr = await asyncio.wait_for(process.communicate(), 60)
        except asyncio.TimeoutError:
            process.kill(); await process.wait()
            raise RpcFailure(-32005, 'Git operation timed out')
        if process.returncode not in allowed:
            raise RpcFailure(-32000, stderr.decode('utf-8','replace').strip() or 'Git operation failed')
        return stdout

    async def root(self, cwd):
        return Path(os.fsdecode((await self.run(directory(cwd), 'rev-parse', '--show-toplevel')).rstrip(b'\n')))

    def selected(self, root, values):
        if not isinstance(values,list) or not values or any(not isinstance(p,str) for p in values):
            raise RpcFailure(-32602, 'Select one or more repository-relative file paths')
        result=[]
        for value in values:
            p=PurePosixPath(value)
            if not value or p.is_absolute() or '..' in p.parts or '.git' in p.parts or '\0' in value:
                raise RpcFailure(-32602, 'Invalid repository-relative file path')
            file=root/value
            if not file.parent.resolve().is_relative_to(root) or file.is_dir():
                raise RpcFailure(-32602, 'Select files inside this repository, not directories')
            if value not in result: result.append(value)
        return sorted(result)

    async def files(self, root):
        records=(await self.run(root,'status','--porcelain=v1','-z','--untracked-files=all')).split(b'\0')
        files=[]; index=0
        while index<len(records):
            raw=records[index];index+=1
            if not raw: continue
            item={'path':os.fsdecode(raw[3:]),'indexStatus':chr(raw[0]),'worktreeStatus':chr(raw[1]),'untracked':raw[:2]==b'??'}
            if raw[:1] in (b'R',b'C') or raw[1:2] in (b'R',b'C'):
                item['originalPath']=os.fsdecode(records[index]);index+=1
            files.append(item)
        return files

    async def fingerprint(self, root, paths):
        # Index blob IDs + exact worktree bytes cover both staged and unstaged edits.
        digest=hashlib.sha256()
        digest.update(await self.run(root,'rev-parse','--verify','HEAD',allowed=(0,128)))
        if not paths: return digest.hexdigest()
        digest.update(await self.run(root,'ls-files','--stage','-z','--',*paths))
        for name in sorted(paths):
            digest.update(os.fsencode(name)+b'\0')
            file=root/name
            if file.is_symlink(): digest.update(b'link\0'+os.fsencode(os.readlink(file)))
            elif file.is_file():
                digest.update(b'file\0'+str(file.stat().st_mode).encode()+b'\0')
                with file.open('rb') as stream:
                    for chunk in iter(lambda:stream.read(65536),b''): digest.update(chunk)
            else: digest.update(b'missing\0')
        return digest.hexdigest()

    async def status(self, body, query):
        root=await self.root(body.get('cwd') or query.get('cwd',[None])[0])
        files=await self.files(root)
        names=sorted({p for item in files for p in (item['path'],item.get('originalPath')) if p})
        head=(await self.run(root,'rev-parse','--verify','HEAD',allowed=(0,128))).decode().strip() or None
        branch=(await self.run(root,'symbolic-ref','--quiet','--short','HEAD',allowed=(0,1))).decode().strip() or None
        return {'root':str(root),'branch':branch,'head':head,'files':files,'diffHash':await self.fingerprint(root,names)}

    async def diff(self, body, query):
        root=await self.root(body['cwd']); paths=self.selected(root,body['paths']); staged=body.get('staged',False)
        before=await self.fingerprint(root,paths)
        args=['diff','--no-ext-diff','--no-textconv','--binary']
        if staged: args.append('--cached')
        raw=await self.run(root,*args,'--',*paths)
        if not staged:
            untracked={f['path'] for f in await self.files(root) if f['untracked']}
            for name in paths:
                if name in untracked:
                    raw+=await self.run(root,'diff','--no-ext-diff','--no-textconv','--no-index','--','/dev/null',str(root/name),allowed=(0,1))
        after=await self.fingerprint(root,paths)
        if before!=after:
            raise RpcFailure(-32009,'Selected files changed while reading the diff; refresh the diff',data={'kind':'staleDiff','diffHash':after})
        return {'root':str(root),'paths':paths,'staged':bool(staged),'diff':raw[:DIFF_LIMIT].decode('utf-8','replace'),
                'truncated':len(raw)>DIFF_LIMIT,'diffHash':after}

    async def checked(self, body):
        root=await self.root(body['cwd']); paths=self.selected(root,body['paths'])
        expected=body.get('expectedDiffHash')
        if not isinstance(expected,str) or not expected:
            raise RpcFailure(-32602,'Review the selected diff and provide its expectedDiffHash')
        actual=await self.fingerprint(root,paths)
        if actual!=expected:
            raise RpcFailure(-32009,'Selected files changed after review; refresh the diff',data={'kind':'staleDiff','diffHash':actual})
        return root,paths

    async def commit(self, body, query):
        root=await self.root(body['cwd'])
        async with self.locks.setdefault(str(root),asyncio.Lock()):
            root,paths=await self.checked(body)
            message=body.get('message','').strip()
            if not message: raise RpcFailure(-32602,'Commit message is required')
            # Explicit selection permits staging these files only. --only preserves
            # every unrelated staged entry and excludes it from this commit.
            await self.run(root,'add','--',*paths)
            summary=await self.run(root,'commit','--only','-m',message,'--',*paths)
            commit=(await self.run(root,'rev-parse','HEAD')).decode().strip()
            return {'commit':commit,'summary':summary.decode('utf-8','replace'),'paths':paths,'root':str(root)}

    async def revert(self, body, query):
        root=await self.root(body['cwd'])
        async with self.locks.setdefault(str(root),asyncio.Lock()):
            root,paths=await self.checked(body)
            untracked={f['path'] for f in await self.files(root) if f['untracked']}
            if untracked.intersection(paths):
                raise RpcFailure(-32602,'Revert does not delete untracked files')
            await self.run(root,'restore','--source=HEAD','--staged','--worktree','--',*paths)
            return {'reverted':paths,'root':str(root)}
