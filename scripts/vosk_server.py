"""Vosk speech recognition server, wire-compatible with whisper-server /inference.

The caller switches between this and whisper-server by changing one URL, so the
same multipart POST is accepted: `file` is used, and `language`,
`response_format`, `prompt`, `translate` and `temperature` are accepted and
ignored. Every response, including errors, is JSON carrying a "text" key --
never HTML -- so a client that reads r.json()["text"] cannot break on an error.

The Model is loaded once and shared; Vosk allows that but a KaldiRecognizer is
not reusable across requests, so one is built per request and discarded.

Usage: python vosk_server.py --model <dir> --host 0.0.0.0 --port 9092
"""

import argparse
import io
import json
import logging
import os
import shutil
import subprocess
import tempfile
import time
import wave

from flask import Flask, Response, jsonify, request
from vosk import KaldiRecognizer, Model, SetLogLevel

SAMPLE_RATE = 16000

_LOGGER = logging.getLogger("vosk-server")


def _json(payload, status=200):
    return Response(json.dumps(payload, ensure_ascii=False), status=status,
                    mimetype="application/json")


def _convert_to_pcm16_mono_16k(raw):
    """ffmpeg fallback for anything that is not already 16kHz mono s16le WAV."""
    if shutil.which("ffmpeg") is None:
        raise RuntimeError("audio is not 16kHz mono s16le WAV and ffmpeg is not installed")
    with tempfile.NamedTemporaryFile(suffix=".input") as src:
        src.write(raw)
        src.flush()
        proc = subprocess.run(
            ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", src.name,
             "-f", "s16le", "-acodec", "pcm_s16le", "-ac", "1", "-ar", str(SAMPLE_RATE), "-"],
            capture_output=True,
        )
    if proc.returncode != 0:
        raise RuntimeError("ffmpeg could not decode the audio: %s"
                           % proc.stderr.decode("utf-8", "replace")[:200].strip())
    return proc.stdout


def load_pcm(raw):
    """Returns 16kHz mono s16le PCM bytes, converting only when necessary."""
    try:
        with wave.open(io.BytesIO(raw)) as wav:
            if (wav.getnchannels() == 1 and wav.getsampwidth() == 2
                    and wav.getframerate() == SAMPLE_RATE
                    and wav.getcomptype() == "NONE"):
                return wav.readframes(wav.getnframes())
    except (wave.Error, EOFError):
        pass
    return _convert_to_pcm16_mono_16k(raw)


def create_app(model_path):
    SetLogLevel(-1)
    started = time.monotonic()
    _LOGGER.info("loading model from %s", model_path)
    model = Model(model_path)
    _LOGGER.info("model loaded in %.1fs", time.monotonic() - started)

    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = int(os.environ.get("VOSK_MAX_UPLOAD_MB", "256")) * 1024 * 1024
    state = {"model_name": os.path.basename(os.path.normpath(model_path))}

    @app.errorhandler(Exception)
    def on_error(exc):
        code = getattr(exc, "code", 500)
        _LOGGER.warning("request failed: %s", exc)
        return _json({"text": "", "error": str(exc)}, status=code if isinstance(code, int) else 500)

    @app.route("/inference", methods=["POST"])
    def inference():
        upload = request.files.get("file")
        if upload is None:
            return _json({"text": "", "error": "no 'file' part in multipart request"}, status=400)

        raw = upload.read()
        if not raw:
            return _json({"text": "", "error": "empty audio file"}, status=400)

        pcm = load_pcm(raw)
        audio_seconds = len(pcm) / (SAMPLE_RATE * 2)

        started_at = time.monotonic()
        recognizer = KaldiRecognizer(model, SAMPLE_RATE)
        recognizer.AcceptWaveform(pcm)
        result = json.loads(recognizer.FinalResult())
        elapsed = time.monotonic() - started_at

        text = (result.get("text") or "").strip()
        _LOGGER.info("%.2fs audio in %.2fs (RTF %.3f): %r",
                     audio_seconds, elapsed, elapsed / audio_seconds if audio_seconds else 0, text[:80])
        return _json({"text": text})

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({"status": "ok", "model": state["model_name"]})

    @app.route("/", methods=["GET"])
    def index():
        return jsonify({
            "service": "vosk-server",
            "model": state["model_name"],
            "endpoints": {"POST /inference": "multipart 'file' -> {\"text\": ...}",
                          "GET /health": "liveness"},
        })

    return app


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, help="Path to the unpacked Vosk model directory")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=9092)
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    app = create_app(args.model)
    from werkzeug.serving import make_server

    server = make_server(args.host, args.port, app, threaded=True)
    _LOGGER.info("listening on http://%s:%d/inference", args.host, args.port)
    server.serve_forever()


if __name__ == "__main__":
    main()
