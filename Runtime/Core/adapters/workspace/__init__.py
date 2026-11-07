"""Concrete workspace Git actions and owned interactive terminals."""
from .git import GitWorkspace
from .terminal import Terminals


async def register(core):
    git=GitWorkspace();terminals=Terminals(core)
    for verb,path,handler in [
        ('GET','/workspace/git/status',git.status),('POST','/workspace/git/status',git.status),
        ('POST','/workspace/git/diff',git.diff),('POST','/workspace/git/commit',git.commit),
        ('POST','/workspace/git/revert',git.revert),('POST','/terminal/open',terminals.open),
        ('GET','/terminal/sessions',terminals.list),('POST','/terminal/write',terminals.write),
        ('POST','/terminal/resize',terminals.resize),('POST','/terminal/close',terminals.close_one),
        ('GET','/terminal/output',terminals.catchup),
    ]:core.register_route(verb,path,handler)
    # HTTP-only ownership callback; no invented model tools are advertised.
    core.register_adapter('organic_workspace','Workspace terminal lifecycle',[],None,close=terminals.close)
