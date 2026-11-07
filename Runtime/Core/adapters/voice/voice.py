"""Thin Organic Core realtime RPC/audio client. Python standard library only."""
import argparse
import base64
import json
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request
import wave

ROOT = pathlib.Path(__file__).resolve().parent


class VoiceClient:
    def __init__(self, base="http://127.0.0.1:18793"):
        self.base = base.rstrip("/")

    def request(self, path, data=None):
        raw = None if data is None else json.dumps(data).encode()
        request = urllib.request.Request(self.base + path, data=raw,
                                         headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            return json.load(error)

    def rpc(self, method, **params):
        return self.request("/rpc", {"method": method, "params": params})

    def events(self, thread_id, since=0):
        query = urllib.parse.urlencode({"threadId": thread_id, "since": since})
        return self.request("/events.json?" + query)

    def send_wav(self, thread_id, filename, chunk_ms=100, realtime=True):
        """Send real PCM16 chunks. Silence at end lets server VAD finish a turn."""
        with wave.open(str(filename), "rb") as audio:
            if audio.getsampwidth() != 2:
                raise ValueError("Input WAV must contain PCM16 samples")
            rate, channels = audio.getframerate(), audio.getnchannels()
            samples = rate * chunk_ms // 1000
            while True:
                data = audio.readframes(samples)
                if not data:
                    break
                result = self.append_pcm(thread_id, data, rate, channels)
                if "error" in result:
                    return result
                if realtime:
                    time.sleep(chunk_ms / 1000)
            for _ in range(12):
                result = self.append_pcm(thread_id, bytes(samples * channels * 2), rate, channels)
                if "error" in result:
                    return result
                if realtime:
                    time.sleep(chunk_ms / 1000)
            return result

    def append_pcm(self, thread_id, data, rate=24000, channels=1):
        return self.rpc("thread/realtime/appendAudio", threadId=thread_id, audio={
            "data": base64.b64encode(data).decode(), "sampleRate": rate,
            "numChannels": channels, "samplesPerChannel": len(data) // (channels * 2)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="http://127.0.0.1:18793")
    parser.add_argument("command", choices=["voices", "start", "audio", "text", "speech", "stop", "events"])
    parser.add_argument("--thread")
    parser.add_argument("--wav")
    parser.add_argument("--text", default="")
    parser.add_argument("--version", choices=["v1", "v2", "v3"])
    parser.add_argument("--voice")
    parser.add_argument("--since", type=int, default=0)
    args = parser.parse_args()
    client = VoiceClient(args.base)
    if args.command == "voices":
        result = client.rpc("thread/realtime/listVoices")
    elif args.command == "start":
        params = {"threadId": args.thread, "outputModality": "audio", "transport": {"type": "websocket"}}
        if args.version:
            params["version"] = args.version
        if args.voice:
            params["voice"] = args.voice
        result = client.rpc("thread/realtime/start", **params)
    elif args.command == "audio":
        result = client.send_wav(args.thread, args.wav)
    elif args.command == "events":
        result = client.events(args.thread, args.since)
    else:
        params = {"threadId": args.thread}
        if args.command != "stop":
            params["text"] = args.text
        method = {"text": "appendText", "speech": "appendSpeech", "stop": "stop"}[args.command]
        result = client.rpc("thread/realtime/" + method, **params)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
