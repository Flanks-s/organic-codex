"""Optional convenience routes; realtime itself remains the official App Server."""
from .chatgpt_call import create_call_on_core


async def register(core):
    async def voices(body, query):
        return await core.rpc("thread/realtime/listVoices", {})

    core.register_route("GET", "/voice/voices", voices)
    async def create(body, query):
        return await create_call_on_core(core, body["threadId"], body["offerSdp"],
                                         body.get("version", "v3"), body.get("voice"))

    core.register_route("POST", "/voice/call", create)
    for suffix, method in (("start", "start"), ("audio", "appendAudio"),
                           ("text", "appendText"), ("speech", "appendSpeech"),
                           ("stop", "stop")):
        async def handler(body, query, method=method):
            return await core.rpc("thread/realtime/" + method, body)
        core.register_route("POST", "/voice/" + suffix, handler)

