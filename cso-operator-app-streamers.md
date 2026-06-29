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

---

## What's Next

- **ProcessClips NiFi refactor** — move Whisper + vLLM calls out of Python backend into NiFi-native InvokeHTTP processors (same pattern as the existing RAG flows). Eliminates backend timeout risk on long clips.
- **Publish history tab** — `.published.json` already written per clip; just needs a UI to surface tweet URLs + timestamps
- **Auto-publish mode** — bypass review queue, post top clips on a schedule
- **Kick support** — credentials already set (`KICK_CLIENT_ID`, `KICK_CLIENT_SECRET`), API integration not built
- **Streamer X handle mapping** — store X handle alongside Twitch login in watch list for credit tagging

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
