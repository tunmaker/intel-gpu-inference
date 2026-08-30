# Speech-to-text: routing Tunisian Derja

There are now two transcription endpoints. They accept **the identical POST**, so
choosing between them is a one-line change — the port, and nothing else.

| Port | Engine | Use for |
|---|---|---|
| 9090 | whisper large-v3 | everything except Derja |
| **9092** | **Vosk `ar-tn` (TARIC)** | **Tunisian Derja** |

Replace `<stt-host>` below with the LAN address of the inference box.

---

## The call — unchanged from whisper

```bash
curl http://<stt-host>:9092/inference \
  -F "file=@audio.wav" \
  -F "response_format=json" \
  -F "language=ar"

# {"text": "..."}
```

`language`, `response_format`, `prompt`, `translate` and `temperature` are all accepted
and **ignored** by the Vosk endpoint. You do not have to strip them — an existing whisper
client works as-is.

```python
WHISPER = "http://<stt-host>:9090/inference"
VOSK    = "http://<stt-host>:9092/inference"

def transcribe(wav_bytes, derja=False):
    url = VOSK if derja else WHISPER
    ...  # the rest of your existing whisper call is unchanged
```

Audio should be 16kHz mono s16le WAV. Other rates, stereo, and compressed formats are
converted server-side with ffmpeg rather than rejected.

---

## Why route Derja separately

Measured on a 37s recording of natural Tunisian speech, both engines on the same audio:

| | Vosk (CPU) | whisper large-v3 (GPU) |
|---|---|---|
| RTF | **0.070** | 0.147 |
| Output | one connected stream | fragmented into short segments |
| Derja/French code-switching | handled (`سافا`, `باهي`, `projet`) | dropped or mangled |
| Repetitions | none observed | repeated phrases and spurious fragments |

Whisper keeps resolving Derja toward Modern Standard Arabic and breaks up when it cannot.
The Vosk model is trained on TARIC, real Tunisian speech, so Derja forms like `شنوة`,
`برشا`, `توا`, `باش` and `نحبك` come out intact.

Vosk is also **2x faster on CPU than whisper is on the Arc**, and its RTF is flat with
clip length. Whisper's degrades sharply on short clips (RTF 0.42 on a 1.6s clip) because
of its fixed 30-second window; Vosk stays near 0.07 regardless.

---

## Differences that may matter to you

**Vosk returns a flat token stream.** No punctuation, no capitalisation, no segment
boundaries or timestamps — just words. Whisper returns text broken into segments. If
anything downstream depends on segmentation, that changes. Vosk can emit word-level
timings, but that is not enabled on this endpoint; ask if you need it.

**Recording level is not critical.** Vosk was unaffected across a 25dB range, from a very
quiet capture (peak 5% of full scale) up to EBU-normalised. Do not add makeup gain hoping
to help it — on the same audio, +22dB made *whisper* noticeably worse and left Vosk
unchanged. Avoid clipping, and otherwise do not worry about level.

**Errors always return JSON.** Every response carries a `text` key, including failures:
`{"text": "", "error": "..."}` with a 4xx/5xx status. The endpoint never returns HTML, so
`r.json()["text"]` is safe on every path, including unknown routes.

---

## Health check

```bash
curl -s http://<stt-host>:9092/health    # {"status":"ok","model":"vosk-model-ar-tn-0.1-linto"}
```

Runs under systemd as `vosk-server.service`, restarts on failure, starts on boot. Model
load takes ~20s, so allow for that after a restart before the first request.
