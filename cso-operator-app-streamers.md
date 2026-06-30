---
layout: single
title: "Streamers — Twitch Clip Pipeline Module for the CSO Operator App"
date: 2026-06-28
classes: wide
categories:
  - blog
tags:
  - nifi
  - kafka
  - twitch
  - whisper
  - vllm
  - cso
  - kubernetes
  - operator-app
---

> **Status:** WORKING — pipeline live, publishing to @TunaStreetTest.
> App repo: `github.com/cldr-steven-matison/cso-operator-app`
> Companion plan: [`cso-operator-app-plan.md`](cso-operator-app-plan.md)

---

## What It Does

The **Streamers module** watches Twitch for top clips from a configured watch list, transcribes them with Whisper, generates a caption with vLLM, queues them in a review UI, and publishes approved clips to X (@TunaStreetTest) with original commentary.

Optional module — enabled at build/deploy time via `MODULES=streamers`. Layers on top of the existing Whisper + vLLM stack with no changes to those services.

---

## Pipeline

```
Twitch API (GQL)
      │
      ▼
FetchClips NiFi flow
  GenerateFlowFile (15 min) → InvokeHTTP POST /api/streamers/fetch-clips
  Backend: Twitch OAuth → GQL VideoAccessToken_Clip → download MP4 → /clips/<id>.mp4
  → PublishKafka → new_clips
      │
      ▼
ProcessClips NiFi flow
  ConsumeKafka ← new_clips → InvokeHTTP POST /api/streamers/process-clip
  Backend: POST whisper-service:8001/transcribe → POST vllm-service:8000/v1/chat/completions
  → PublishKafka → processed_clips
      │
      ▼
Streamers Page — Review UI
  Watch clip · Edit caption · Add commentary · Approve → POST /api/streamers/publish
      │
      ▼
X API: tweepy v1 media_upload (chunked) + v2 create_tweet
```

All NiFi flows live under a `StreamersApp` parent PG — separate from `CSOOperatorApp`.

---

## Existing Services Used

| Service | Use |
|---|---|
| `whisper-service:8001` | `POST /transcribe` — multipart MP4 → `{"text": "..."}` |
| `vllm-service:8000` | `POST /v1/chat/completions` — transcript → caption |
| Kafka (Strimzi) | `new_clips`, `processed_clips` topics (1 partition each) |
| NiFi (CFM) | 3 process groups under `StreamersApp` PG |

New per this module:
- Twitch + X API credentials injected via `kubectl set env` (never in YAML)
- PVC at `/clips` for MP4 storage — `streamers/pvc.yaml`
- Kafka topics — `streamers/kafka-topics.yaml`

---

## Module System

`MODULES` is a build-time flag that controls which optional tabs are active. `build-modules.py` only recognizes `streamers` as a known module; `efm` and `rag` are handled purely at the frontend/backend level via the same env var.

```
Dockerfile ARG MODULES=''
  → VITE_MODULES baked into React bundle → shows/hides nav tabs
  → ENV MODULES in backend image → registers /api/streamers/* routes only if "streamers" present
```

**Frontend** (`App.tsx`): tabs for `efm`, `rag`, `streamers` only render if their name appears in `VITE_MODULES`.

**Backend** (`main.py`): `efm` router is always included. `streamers` router is conditionally registered. `rag` panels use always-present routers (query, ingest, nifi, qdrant, kafka).

| `MODULES=` value | Active tabs |
|---|---|
| *(empty)* | Operator only |
| `rag` | Operator + RAG |
| `streamers` | Operator + Streamers |
| `rag,streamers` | Operator + RAG + Streamers |
| `efm,rag,streamers` | All tabs |

---

## Deploy

```bash
cd ~/cso-operator-app
make deploy MODULES=rag,streamers
```

App is permanently at **http://127.0.0.1:8000** via `minikube tunnel` (LoadBalancer service).
`minikube tunnel` must be running — it's the first step in the terminal setup and also auto-opens Chromium.

After any deploy that resets the pod, re-inject credentials:

```bash
source ~/.env
kubectl set env deploy/cso-operator-app \
  NIFI_USERNAME=admin \
  NIFI_PASSWORD="${NIFI_ADMIN_PASS}" \
  TWITCH_CLIENT_ID="${TWITCH_CLIENT_ID}" \
  TWITCH_CLIENT_SECRET="${TWITCH_CLIENT_SECRET}" \
  KICK_CLIENT_ID="${KICK_CLIENT_ID}" \
  KICK_CLIENT_SECRET="${KICK_CLIENT_SECRET}" \
  X_API_KEY="${X_API_KEY}" \
  X_API_SECRET="${X_API_SECRET}" \
  X_ACCESS_TOKEN="${X_ACCESS_TOKEN}" \
  X_ACCESS_TOKEN_SECRET="${X_ACCESS_TOKEN_SECRET}" \
  STREAMERS_WATCH_LIST="stableronaldo"
```

### Rebuild Whisper image

Only needed when `whisper/Dockerfile.whisper` changes:

```bash
eval $(minikube docker-env)
docker build -t streamwhisper:latest -f whisper/Dockerfile.whisper .
kubectl rollout restart deploy/whisper-server
```

### Scale down idle services

EFM, SSB, Schema Registry, and MiNiFi are not needed for the Streamers pipeline:

```bash
kubectl scale deploy efm schema-registry ssb-mve ssb-sse -n cld-streaming --replicas=0
kubectl delete pod minifi-agent-k8s -n cld-streaming
# ssb-postgresql stays running (EFM/Schema Registry config is stored there)
```

Restore: `--replicas=1` and `kubectl apply -f ~/ClouderaStreamingOperators/minifi-agent-pod.yaml`

---

## Streamers API Endpoints

| Endpoint | Called by |
|---|---|
| `POST /api/streamers/fetch-clips` | NiFi FetchClips (every 15 min) |
| `POST /api/streamers/process-clip` | NiFi ProcessClips (per Kafka message) |
| `GET  /api/streamers/queue` | Review UI on load |
| `GET  /api/streamers/clip/{clip_id}` | Video player in ClipCard |
| `POST /api/streamers/publish` | Approve button |
| `POST /api/streamers/skip` | Skip button |
| `GET  /api/streamers/topics` | Topics panel (30s cached) |
| `POST /api/streamers/reset` | Reset Kafka button |
| `GET  /api/streamers/watchlist` | Watch List section |
| `POST /api/streamers/watchlist` | Watch List add/remove |
| `GET  /api/streamers/flows` | Pipeline Status panel (30s polled) |
| `POST /api/streamers/flows/{name}/start\|stop` | Flow start/stop buttons |

---

## Clip Fetch Behavior

- Fetches 20 clips per streamer, filters to ≥ 45s, sorts longest-first
- Caps at **5 clips per streamer per run**
- Deduplication via `/clips/.seen_clips.json` — no re-download of previously fetched clips
- Skip/publish state persisted to `/clips/.skipped.json` and `/clips/.published.json`
- Reset Kafka button wipes MP4s, seen/skipped/published lists, and deletes both topics

---

## Whisper Configuration

`whisper/Dockerfile.whisper` — Whisper-large-v3, Flash Attention 2, CUDA 12.4:

```python
pipe(tmp_path, chunk_length_s=60, batch_size=24, return_timestamps=True)
```

- `chunk_length_s=60` — matches Twitch clip max duration
- `batch_size=24` — GPU-tuned for RTX 4060
- Temp file written as `.mp4` (matches actual clip format)
- Keep the server synchronous — `run_in_executor` broke startup

---

## NiFi ProcessClips Concurrency

`streamers/StreamersApp.json` sets `concurrentlySchedulableTaskCount=3` on `InvokeHTTP` and `PublishKafka_2_6` in ProcessClips. NiFi sends 3 clips to the backend simultaneously; Whisper queues them at the HTTP level. ConsumeKafka stays at 1 (single Kafka partition).

---

## Key Technical Gotchas

| Issue | Fix |
|---|---|
| Twitch CDN changed 2024 — thumbnail→.mp4 URL dead | GQL `VideoAccessToken_Clip` query → `sourceURL?sig=&token=` |
| aiokafka hangs after manual `seek()` with `async for` | Use `getmany(tp, timeout_ms=5000)` one-shot fetch |
| Strimzi created 1 partition despite spec saying 3 | Hardcode `TopicPartition(topic, 0)` |
| X API v1.1 `update_status` retired | tweepy v2 `create_tweet` + v1 `media_upload(chunked=True)` |
| X API 402 "no credits" | Pay-per-use billing — add credits at developer.x.com |
| HuggingFace pipeline has no `beam_size` param | Use `num_beams` or omit — default is already greedy |
| `asyncio.Semaphore` + `run_in_executor` in Whisper | Broke server startup — HTTP queuing at NiFi layer is sufficient |
| NiFi InvokeHTTP URL to app | Use `http://cso-operator-app.default.svc.cluster.local:8000/api/...` — NodePort 30080 is external only and will timeout |
| Kick public API `/clips` endpoint | Returns 404 — use `kick.com/api/v2/clips?channel=<slug>` with browser `User-Agent` + `Referer: https://kick.com/` headers |
| Kick HLS clips need ffmpeg remux | `clip_url` is `.m3u8` — download with `ffmpeg -c copy -movflags +faststart`; do NOT re-encode with libx264 (too slow) |
| Whisper can't read MP4 directly | Whisper server saves uploads as `.wav`; soundfile fails on MP4 content — extract 16kHz mono WAV with ffmpeg before uploading |
| Parallel fetch race condition | `seen` set must be updated before download, not after, to prevent concurrent streamers downloading the same clip |

---

## What's Next

- **ProcessClips NiFi refactor** — ✓ PLANNED (see section below)
- **Publish history tab** — `.published.json` already written per clip; just needs a UI to surface tweet URLs + timestamps
- **Auto-publish mode** — bypass review queue, post top clips on a schedule
- **Post to real X account** — ✓ PLANNED (see section below)
- **GPU optimization** — Whisper CPU + 5B caption model — see [`gpu-optimization-plan.md`](gpu-optimization-plan.md)

---

## Posting to a Real X Account (Multi-Account Setup)

**Goal:** Keep the X app registered under @TunaStreetTest (developer account) but post to a different real account. No public app needed — only you can authorize it.

### How It Works

The X app owner (developer account) and the account that grants OAuth access are separate concepts. The app stays registered under @TunaStreetTest. Your real account authorizes the app via OAuth and you capture those tokens. Posts flow through the same tweepy code — just different credentials.

### Steps

**1. Confirm OAuth 1.0a User Context is enabled on the app**

In [developer.twitter.com](https://developer.twitter.com) (logged in as @TunaStreetTest):
- Open the app → Settings → User authentication settings
- Enable OAuth 1.0a
- Set callback URL: `http://localhost:3000/callback` (or any localhost port)
- Save

**2. Run the one-shot OAuth dance for your real account**

```python
# oauth_dance.py — run once, prints real account tokens
import tweepy

API_KEY = "..."        # your app's consumer key (from @TunaStreetTest dev portal)
API_SECRET = "..."     # your app's consumer secret

auth = tweepy.OAuthHandler(API_KEY, API_SECRET, callback="oob")
print("Go to this URL and log in as your REAL account:")
print(auth.get_authorization_url())

pin = input("Enter the PIN from Twitter: ")
auth.get_access_token(pin)

print(f"\nX_ACCESS_TOKEN={auth.access_token}")
print(f"X_ACCESS_TOKEN_SECRET={auth.access_token_secret}")
```

Run `python oauth_dance.py` — it prints a URL, you open it logged in as the real account, approve, paste the PIN. Done.

**3. Inject real account tokens into the pod**

```bash
source ~/.env
kubectl set env deploy/cso-operator-app \
  X_ACCESS_TOKEN="<real_account_access_token>" \
  X_ACCESS_TOKEN_SECRET="<real_account_access_token_secret>"
# X_API_KEY and X_API_SECRET stay the same (they're the app's consumer keys, not account-specific)
```

**4. Verify**

Post a test clip through the review UI — it should appear on the real account, not @TunaStreetTest.

### Notes

- App stays private — no listing, no approval process, only you can authorize
- Consumer key/secret belong to the app (stay the same)
- Access token/secret belong to the account (swap these to switch accounts)
- To switch back to @TunaStreetTest, re-inject the original access token/secret
- Add `oauth_dance.py` to `.gitignore` — don't commit it with keys filled in

---

## ProcessClips NiFi Refactor Plan

Move Whisper transcription and vLLM caption generation out of the Python backend into NiFi-native InvokeHTTP processors — same pattern as the existing `StreamToWhisper` and `StreamTovLLM` RAG flows. Eliminates backend HTTP timeout risk; all intermediate state is visible in NiFi as flowfile attributes.

### Why

Current `ProcessClips` PG: `ConsumeKafka → InvokeHTTP POST /process-clip → PublishKafka`

The backend's `/process-clip` does: ffmpeg WAV extract → POST whisper:8001 → POST vllm:8000 → clean caption → build tweet → return JSON. If Whisper takes 120s on a long Kick clip, NiFi's InvokeHTTP timeout fires and the clip is lost. In NiFi we can set per-step timeouts, see intermediate flowfile content, and retry individual steps.

### New ProcessClips NiFi Flow (12 processors)

```
ConsumeKafka_2_6 (new_clips)
  group.id: StreamersProcessClips
  auto.offset.reset: earliest
  concurrentlySchedulableTaskCount: 1   ← keep at 1; Whisper is synchronous
  ↓ flowfile = JSON clip record from Kafka

EvaluateJsonPath
  Destination: flowfile-attribute
  clip_id:       $.clip_id
  source:        $.source
  streamer:      $.streamer
  title:         $.title
  clip_path:     $.clip_path
  url:           $.url
  thumbnail_url: $.thumbnail_url
  duration:      $.duration
  created_at:    $.created_at
  ↓ flowfile unchanged; attributes populated

InvokeHTTP  [GET WAV]
  HTTP Method:  GET
  Remote URL:   http://cso-operator-app.default.svc.cluster.local:8000/api/streamers/wav/${clip_id}
  Read Timeout: 90 secs
  Connection Timeout: 10 secs
  → Response relationship only (route Failure/No Retry to error log)
  ↓ flowfile = raw WAV bytes (16kHz mono)

UpdateAttribute
  filename:  ${clip_id}.wav
  mime.type: audio/wav

InvokeHTTP  [POST Whisper]
  HTTP Method:          POST
  Remote URL:           http://whisper-service.default.svc.cluster.local:8001/transcribe
  Content-Type:         ${mime.type}
  send-message-body:    true
  set-form-filename:    true
  file:                 ${filename}
  form-body-form-name:  file
  Read Timeout:         300 secs
  Connection Timeout:   10 secs
  → Response → flowfile = {"text": "transcript..."}

EvaluateJsonPath
  Destination: flowfile-attribute
  transcript: $.text
  ↓ flowfile unchanged; transcript attribute set

ReplaceText  [build vLLM request]
  Replacement Strategy: Regex Replace
  Regular Expression: (?s)(^.*$)
  Replacement Value:
    {
      "model": "Qwen/Qwen2.5-1.5B-Instruct",
      "messages": [
        {"role": "system", "content": "You are a hype gaming content creator writing tweets. Output ONLY the tweet text — no labels, no quotes around it."},
        {"role": "user", "content": "Write a punchy tweet reaction (under 200 chars) to this clip by ${streamer:escapeJson()}. React to what actually happened — quote the funniest or wildest line if it fits. Use 1-2 emojis. Keep it natural, no hashtags. Clip title: '${title:escapeJson()}'. Transcript: ${transcript:substring(0, 600):escapeJson()}"}
      ],
      "max_tokens": 120,
      "temperature": 0.85
    }
  ↓ flowfile = vLLM request JSON body

InvokeHTTP  [POST vLLM]
  HTTP Method:     POST
  Remote URL:      http://vllm-service.default.svc.cluster.local:8000/v1/chat/completions
  Content-Type:    application/json
  Read Timeout:    60 secs
  Connection Timeout: 10 secs
  → Response → flowfile = OpenAI-format JSON response

EvaluateJsonPath
  Destination: flowfile-attribute
  raw_caption: $.choices[0].message.content
  ↓ flowfile unchanged; raw_caption attribute set

ReplaceText  [build processed_clips Kafka message]
  Replacement Strategy: Regex Replace
  Regular Expression: (?s)(^.*$)
  Replacement Value:
    {"clip_id":"${clip_id}","source":"${source}","streamer":"${streamer}","title":"${title:escapeJson()}","url":"${url}","thumbnail_url":"${thumbnail_url}","duration":${duration},"created_at":"${created_at}","clip_path":"${clip_path}","transcript":"${transcript:escapeJson()}","raw_caption":"${raw_caption:escapeJson()}"}

PublishKafka_2_6  (processed_clips)
  topic: processed_clips
  bootstrap.servers: my-cluster-kafka-bootstrap.cld-streaming.svc:9092
```

### Backend Changes Required

#### 1. Add `GET /api/streamers/wav/{clip_id}` (router + service)

New endpoint in `routers/streamers.py`:
```python
@router.get("/wav/{clip_id}")
async def serve_wav(clip_id: str):
    """Extract 16kHz mono WAV from MP4. Called by NiFi ProcessClips GET WAV step."""
    if not re.match(r'^[A-Za-z0-9_\-]+$', clip_id):
        raise HTTPException(status_code=400, detail="Invalid clip_id")
    mp4_path = Path(settings.CLIP_STORAGE_PATH) / f"{clip_id}.mp4"
    if not mp4_path.exists():
        raise HTTPException(status_code=404, detail="Clip not found")
    wav_path = Path(settings.CLIP_STORAGE_PATH) / f"{clip_id}.wav"
    import asyncio, subprocess
    proc = await asyncio.to_thread(
        subprocess.run,
        ["ffmpeg", "-y", "-i", str(mp4_path), "-vn", "-ac", "1", "-ar", "16000", str(wav_path)],
        capture_output=True, timeout=60,
    )
    if proc.returncode != 0 or not wav_path.exists():
        raise HTTPException(status_code=500, detail="ffmpeg WAV extraction failed")
    return FileResponse(str(wav_path), media_type="audio/wav")
```

WAV files accumulate alongside MP4s in `/clips/`. Add `*.wav` to reset cleanup in `reset_kafka()`.

#### 2. Update `clip_queue()` in `services/streamers.py`

Kafka messages now store `raw_caption` (not final tweet text). Apply `_clean_caption` + `_build_tweet` at queue-read time so the catalog and suffix format are always fresh:

```python
# Inside the per-message loop in clip_queue():
raw = record.get("raw_caption")
if raw and not raw.startswith("["):
    x_handle = get_x_handle(record.get("streamer", ""))
    record["caption"] = _build_tweet(
        _clean_caption(raw),
        record.get("source", "twitch"),
        record.get("streamer", ""),
        x_handle,
    )
# Fall through: old records with pre-built "caption" field are used as-is
```

#### 3. Keep `POST /api/streamers/process-clip`

Endpoint stays for manual/debug use. NiFi will no longer call it once the new ProcessClips PG is live.

#### 4. Kafka reset — wipe WAV files

In `reset_kafka()`, add WAV cleanup alongside MP4:
```python
for wav in glob.glob(str(storage / "*.wav")):
    Path(wav).unlink(missing_ok=True)
```

### Rollout Steps

1. Add `GET /wav/{clip_id}` endpoint — deploy app
2. Test endpoint manually: `curl http://localhost:8000/api/streamers/wav/<clip_id> -o test.wav`
3. Update `clip_queue()` to compute caption from `raw_caption` — deploy app
4. Update `setup-streamers-flows.py` to build new 12-processor ProcessClips PG
5. Stop current ProcessClips PG in NiFi UI
6. Run updated `setup-streamers-flows.py` to replace ProcessClips PG
7. Start new ProcessClips PG — verify flowfile attributes visible in NiFi
8. End-to-end test: fetch clips → watch NiFi → processed_clips → review UI shows transcripts + captions
9. Update `StreamersApp.json` to snapshot the new flow for future import

### Key Gotchas

| Risk | Mitigation |
|---|---|
| Whisper server still synchronous (no semaphore) | Keep ConsumeKafka concurrentlySchedulableTaskCount=1 |
| WAV file left on disk if NiFi crashes mid-flow | Reset button now also wipes *.wav |
| Old processed_clips records have `caption` not `raw_caption` | clip_queue() falls back to raw `caption` field for old records |
| InvokeHTTP WAV URL uses EL `${clip_id}` — must set Dynamic Property disabled | clip_id comes from EvaluateJsonPath attribute, use it directly in URL field |
| Return Timestamps must be True in Whisper for clips >30s | Already set in Whisper ConfigMap — no change needed |

---

## Session History

### Session 2 (2026-06-28)

| Feature | Details |
|---|---|
| Kafka topic panels | Live message count + last 5 records for `new_clips` and `processed_clips` in the Streamers UI |
| Reset Kafka button | Deletes topics via Kafka Admin API, wipes `/clips/*.mp4`, resets `.seen_clips.json` |
| Dismiss on publish | Cards vanish after 1.2s "Posted ✓" flash; Refresh clears stale dismissed state |
| Fallback captions | 5 rotating Tuna Street fallbacks when vLLM returns empty |
| Duration filter | Fetch 20 clips per streamer, drop < 45s, sort longest-first, cap at 3 per streamer |
| File-exists gate | Review queue only surfaces clips whose MP4 is on disk |
| 404 on missing file | Publish endpoint returns actionable 404 instead of opaque 502 |
| RBAC | Added `kafkatopics get/list/delete` to `cso-operator-app-writer` role in `cld-streaming` |

### Session 3 (2026-06-29)

| Change | Details |
|---|---|
| NiFi group ID cache | `_resolve_streamer_groups` BFS result cached 5 min |
| Parallel Kafka consumers | `topic_stats` runs both consumers concurrently via `asyncio.gather` |
| topic_stats result cache | 30s TTL — repeated Refresh clicks don't spin new consumers |
| Flow poll 5s → 30s | Frontend poll interval reduced 6× |
| Page-visibility pause | Poll stops when browser tab is hidden, resumes on focus |
| Lazy thumbnails | `loading="lazy"` on clip thumbnail images |
| Skip persistence | Skip writes clip_id to `/clips/.skipped.json`; filtered from queue on next load |
| Publish persistence | `publish_clip` writes clip_id to `/clips/.published.json` on successful tweet |
| Reset clears skip+publish | Reset Kafka button also wipes `.skipped.json` and `.published.json` |
| Video player in review | `<video controls preload="none">` in each ClipCard, served via `GET /api/streamers/clip/{clip_id}` |

### Session 6 (2026-06-29)

| Change | Details |
|---|---|
| Kick.com clip support | `kick:slug` prefix in watch list routes to Kick; bare names stay Twitch. `kick.com/api/v2/clips` with browser headers fetches clips |
| Kick HLS download | ffmpeg `-c copy -movflags +faststart` remuxes HLS `.m3u8` to MP4 in seconds |
| WAV pre-extraction for Whisper | ffmpeg extracts 16kHz mono WAV before Whisper upload — fixes transcription for both Kick and Twitch |
| Platform badge in review queue | TWITCH/KICK badge always shown next to streamer name; defaults to twitch for old clips |
| Platform badge in Kafka Topics panel | `src` column added to topic record table |
| Platform-aware watch list UI | Twitch/Kick toggle + auto-prefixes `kick:` when adding; pills show platform badge |
| Caption always names platform | vLLM prompt requires "Twitch" or "Kick" in every generated caption |
| Clips per run 5 → 2 | Reduces fetch time and NiFi timeout risk |
| Parallel streamer fetch | All streamers fetched concurrently via `asyncio.gather` |
| Seen-set race condition fix | Clip marked seen before download so concurrent streamers skip duplicates |
| ffmpeg added to app Dockerfile | Required for HLS remux and WAV extraction in the app container |

### Session 5 (2026-06-29)

| Change | Details |
|---|---|
| Approve → queue | Approve button now instant — adds to `.pending_publish.json`, returns `Queued #N`. NiFi PublishClip flow changed to `GenerateFlowFile (120s) → InvokeHTTP POST /api/streamers/publish-next` to rate-limit X posts |
| `/approve` + `/publish-next` endpoints | Approve queues to `.pending_publish.json`; publish-next pops one and calls tweepy. `/publish` kept for direct/debug use |
| Hashtag normalizer | `_clean_caption()` now normalizes `#ALL_CAPS` → `#TitleCase` and `#WORD_UNDERSCORE` → `#WordUnderscore` |
| Caption label fix | System message tells vLLM output-only; `_clean_caption()` strips `**Label:**` prefix and surrounding quotes as fallback |
| All polls slowed + visibility pause | HealthBar 30s→60s, Operators 15s→60s, PodSummary 5s→30s, NifiControls 4s→30s. All now pause when browser tab is hidden |
| HealthBar operators call removed | HealthBar was calling `k8sOperators()` every tick on every tab just for the Flink dot — removed. Operators component (Operator tab only) already covers it |
| NiFi URL for internal calls | Always `http://cso-operator-app.default.svc.cluster.local:8000/api/...` — not NodePort 30080 |

### Session 8 (2026-06-30)

| Change | Details |
|---|---|
| Fetch mode toggle | Watch List card has `Recent \| Top Clips` toggle + period selector (`1 Month \| All Time`). Mode persisted to `/clips/.fetch_mode.json` — survives pod restarts |
| Twitch top clips | Top mode sets `started_at` to 30 days ago (month) or omits it (all time); sorts by `view_count` instead of duration. Pulled many high-view historical clips successfully |
| Kick top clips | Kick channel endpoint only accepts `sort=date` — 422 on any other sort value. No time window support. Top mode fetches 20 most recent and sorts by `view_count` client-side |
| Kick wrong-channel bug fixed | Global `kick.com/api/v2/clips?channel=slug` param is ignored server-side — was returning random global clips. Switched to `kick.com/api/v2/channels/{slug}/clips` (channel-specific endpoint). Added client-side `channel.slug` validation as safety net |
| Clip card links + metadata | Title links to clip URL on platform; streamer name links to Twitch/Kick profile; `@x_handle` links to X. View count and created date shown inline |
| x_handle in queue response | `get_x_handle()` called at queue-read time in `clip_queue()`; injected into each clip dict returned to frontend |
| Commentary textarea removed | Caption field is the only editable field — commentary box removed. Caption textarea taller (rows=4) |
| Approve message cleaned | Removed "~2 min" time estimate from post-approve confirmation |
| X multi-account plan | Documented OAuth 1.0a dance to post to real account via app registered under @TunaStreetTest — see "Posting to a Real X Account" section |
| GPU optimization plan | New `gpu-optimization-plan.md` — VRAM analysis for RTX 4060 8GB, three options for running 5B model alongside Whisper, open questions before acting |
| Full Kafka reset | Wiped 76 stale clips + both topics after Kick bug discovered — fresh start with correct channel filtering |

### Session 4 (2026-06-29)

| Change | Details |
|---|---|
| Clips per streamer 2 → 5 | `fetch_clips` cap raised — fetch pool is 20 clips (≥45s, longest-first) |
| Deploy without EFM tab | `make deploy MODULES=rag,streamers` omits EFM from frontend |
| Whisper `chunk_length_s=60` | Matches clip max duration; fewer pipeline passes per clip |
| ProcessClips concurrency | `concurrentlySchedulableTaskCount=3` on InvokeHTTP + PublishKafka in ProcessClips |
| Kafka Topics auto-load | Topics panel fetches on page mount; 30s backend TTL cache |
| Temp file `.wav` → `.mp4` | Whisper server now writes clips with correct extension |
| Router imports cleaned up | `os` and `json` moved to module level in `routers/streamers.py` |
