# Piper TTS server — consumer handoff

Text-to-speech now runs on the `llama` box instead of on the Pi. Point your synthesis
calls at it and delete the local Piper path.

**Endpoint:** `http://<piper-host>:9091/`
No auth, no API key, plain HTTP on the LAN.

Replace `<piper-host>` throughout with the LAN address of the box running the inference
stack — the same host you already call for whisper on port 9090. Ask whoever handed you
this doc for the address, or pin it in your config rather than hardcoding it in a helper.

> Speech-to-text is covered separately in
> [derja-stt-consumer-handoff.md](derja-stt-consumer-handoff.md) — Tunisian Derja now
> routes to a different port than the rest.

---

## The call

`POST /` with a JSON body. You get **WAV bytes** back in the response body.

```bash
curl http://<piper-host>:9091/ \
  -H "Content-Type: application/json" \
  -d '{"text":"مرحبا، كيف حالك اليوم؟"}' \
  -o speech.wav
```

```python
import json, urllib.request

def synthesize(text, voice=None, length_scale=None):
    """Returns WAV bytes: 22050 Hz, 16-bit, mono."""
    payload = {"text": text}
    if voice:
        payload["voice"] = voice
    if length_scale:
        payload["length_scale"] = length_scale
    req = urllib.request.Request(
        "http://<piper-host>:9091/",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()
```

### Request fields

| Field | Required | Notes |
|---|---|---|
| `text` | **yes** | The text to speak. |
| `voice` | no | Voice name (below). Omit to get Arabic. |
| `length_scale` | no | Speaking rate. Below 1.0 is faster, above is slower. Default 1.0. |
| `noise_scale`, `noise_w_scale` | no | Generator noise. Leave alone unless you have a reason. |

### Response

Raw WAV bytes — `Content-Type: audio/wav`, **22050 Hz, 16-bit, mono**, for all three
voices. Write it to a file or feed it straight to your player. There is no JSON envelope
and no base64; the body *is* the audio.

---

## Voices

Pick per request based on the script of the reply text. All three are loaded in the same
server — switching costs nothing and needs no restart.

| Voice | Use for |
|---|---|
| `ar_JO-kareem-medium` | **Arabic** — the default if you omit `voice` |
| `fr_FR-siwis-medium` | French |
| `en_US-lessac-medium` | English |

`GET /voices` returns the installed voices as JSON if you want to check at runtime rather
than hardcoding.

---

## Four things that will bite you

**1. `Content-Type: application/json` on the request is mandatory.** Without it the
server returns 500 — it reads the raw body, and Flask swallows the body as form data if
you send the wrong header. This is the most likely reason a working `curl` breaks when
you port it to a client library.

**2. An unknown voice name silently returns the default voice, with HTTP 200.** You will
not get an error. If you send `"voice": "ar-JO-kareem-medium"` (hyphen instead of
underscore) you get Arabic anyway and never notice — until you send French and get an
Arabic speaker reading it. Match the names above exactly.

**3. Empty or missing `text` returns HTTP 500, not 400.** Check for empty strings on your
side before calling; don't rely on a clean error.

**4. The first request for a given voice is ~1s slower.** Voices other than Arabic load
lazily on first use. If first-utterance latency matters for French or English, send a
one-word warmup request at startup.

---

## What to expect for speed

Measured end-to-end from the Pi, including the network round trip:

| Voice | Audio produced | Wall time |
|---|---|---|
| `ar_JO-kareem-medium` | 2.76s | **0.19s** |
| `fr_FR-siwis-medium` | 1.58s | 0.09s |
| `en_US-lessac-medium` | 1.70s | 0.09s |

For reference, the Pi's local Piper took ~9.6s to produce ~2.3s of Arabic. This is
roughly **50x faster**. Arabic costs about twice the others because it runs an extra
diacritization pass — that is expected, not a fault.

Synthesis is faster than playback, so you can start playing as soon as the response
lands. Concurrent requests work fine; nine at once were handled without error.

---

## Health checks

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://<piper-host>:9091/voices   # 200 = up
```

`GET /voices` is the cheap liveness probe. `GET /` returns a browser test page you can
open to try voices by hand. `GET /info` reports the default voice and the timing of the
most recent synthesis.

The service runs under systemd on `llama` as `piper-server.service`, restarts on failure,
and comes back on boot. If it looks wedged, whoever administers `llama` can run
`systemctl --user restart piper-server`.

---

## On the Pi side

Remove the local Piper install, its venv, and the downloaded `.onnx` voices — they are
just consuming disk and are no longer used. Keep a sensible timeout (30s is generous) and
handle connection errors, since TTS now depends on the LAN and on `llama` being up. If
you want a fallback for when the network is down, that is a deliberate design decision
worth raising rather than something this server provides.
