"""Thin HTTP aliases to existing official App Server methods.

No separate Skill, MCP or plugin execution engine is introduced. Model turns
continue through Core /rpc and the original App Server agent loop.
"""
import json
from pathlib import Path

METHODS = {
    "/app-server/skills/list": "skills/list",
    "/app-server/mcp/status": "mcpServerStatus/list",
    "/app-server/mcp/call": "mcpServer/tool/call",
    "/app-server/plugins/list": "plugin/list",
    "/app-server/plugins/installed": "plugin/installed",
    "/app-server/plugins/read": "plugin/read",
    "/app-server/apps/list": "app/list",
}


def runtime_dependencies():
    """Locate the existing official Mac bundle; presence is not an execution claim."""
    root = Path.home() / ".cache/codex-runtimes/codex-primary-runtime"
    manifest = root / "runtime.json"
    metadata = json.loads(manifest.read_text()) if manifest.is_file() else {}
    paths = {"python": root / "dependencies/python/bin/python3",
             "pdftoppm": root / "dependencies/native/poppler/bin/pdftoppm",
             "pdfinfo": root / "dependencies/native/poppler/bin/pdfinfo",
             "pdfArtifactMarker": root / "plugins/openai-primary-runtime/plugins/pdf/skills/pdf/container_tools/mark_artifact_operation_started.mjs"}
    return {"root": str(root), "bundleVersion": metadata.get("bundleVersion"),
            "paths": {key: {"path": str(path), "exists": path.is_file()} for key, path in paths.items()},
            "scope": "Existing component paths only; no install, credential access or execution."}


async def register(core):
    for path, method in METHODS.items():
        async def endpoint(body, query, method=method):
            if method == "mcpServer/tool/call":
                session = core.sessions.get(body.get("threadId"))
                if session is not None and not session.get("loaded"):
                    await core.rpc("thread/resume", {"threadId": body["threadId"], "excludeTurns": True})
            return await core.rpc(method, body)
        core.register_route("POST", path, endpoint)
    async def dependencies(body, query):
        return runtime_dependencies()
    core.register_route("GET", "/app-server/runtime-dependencies", dependencies)
