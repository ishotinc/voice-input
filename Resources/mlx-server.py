"""Private loopback ASR worker; one model, serialized requests, no speech logs/files."""
import argparse
import io
import json
import wave
from email.parser import BytesParser
from email.policy import default
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


def decode_request(content_type, body):
    message = BytesParser(policy=default).parsebytes(
        b"Content-Type: " + content_type.encode("ascii") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body)
    if not message.is_multipart():
        raise ValueError("multipart required")
    fields = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name or name in fields:
            raise ValueError("duplicate or missing field")
        fields[name] = part.get_payload(decode=True)
    with wave.open(io.BytesIO(fields["file"])) as audio:
        if (audio.getnchannels(), audio.getframerate(), audio.getsampwidth()) != (1, 16000, 2):
            raise ValueError("expected mono 16 kHz PCM16")
        frames = audio.readframes(audio.getnframes())
    if not frames or len(frames) % 2:
        raise ValueError("empty or invalid PCM")
    return frames, fields.get("language", b"ja").decode(), fields.get("prompt", b"").decode()[:2000]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--model", required=True)
    args = parser.parse_args()
    if not Path(args.model).is_dir():
        raise ValueError("local model missing")
    import numpy as np
    import mlx.core as mx
    import mlx_whisper
    if not mx.metal.is_available():
        raise RuntimeError("Metal unavailable")

    def recognize(pcm, language="ja", prompt=""):
        audio = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0
        result = mlx_whisper.transcribe(audio, path_or_hf_repo=args.model,
            language=language, initial_prompt=prompt or None, temperature=0.0,
            condition_on_previous_text=False, without_timestamps=True, verbose=None)
        mx.synchronize()
        return result["text"].strip()

    # Compile/load before health reports ready, rather than during the first dictation.
    recognize(bytes(16000 * 2))

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass

        def answer(self, code, value):
            payload = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            if self.path == args.prefix + "/health" and not self.headers.get("Origin"):
                self.answer(200, {"status": "ok"})
            else:
                self.answer(404, {})

        def do_POST(self):
            if self.path != args.prefix + "/inference" or self.headers.get("Origin"):
                self.answer(404, {})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 65_000_000:
                    raise ValueError("size")
                self.connection.settimeout(30)
                body = self.rfile.read(length)
                if len(body) != length:
                    raise ValueError("truncated")
                pcm, language, prompt = decode_request(self.headers.get("Content-Type", ""), body)
                text = recognize(pcm, language, prompt)
                self.answer(200, {"text": text})
            except Exception:
                self.answer(500, {"error": "recognition failed"})

    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
