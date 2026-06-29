---
layout: single
title: "Streamers — Twitch/Kick Clip Pipeline Module for the CSO Operator App"
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

> **Status:** WORKING — pipeline live, publishing to @TunaStreetTest. Skip/publish state now persisted to PVC. Video playback embedded in review queue. Performance optimized (NiFi group ID cache, parallel Kafka consumers, 30s poll, page-visibility pausing). Known issue: Whisper transcription times out NiFi InvokeHTTP on 45-60s clips (processing architecture needs refactor to NiFi-native processors).  
> Architecture seed: [`files/Streamers.md`](files/Streamers.md)  
> Companion plan: [`cso-operator-app-plan.md`](cso-operator-app-plan.md)  
> App repo: `github.com/cldr-steven-matison/cso-operator-app`

---

## What We Are Building

The **Streamers module** adds a fully automated clip curation pipeline to the CSO Operator App. It watches Twitch (and optionally Kick) for top clips from a configured list of streamers, runs them through the existing AI stack (Whisper for transcription, vLLM for commentary generation), queues them in a review UI, and publishes approved clips to X (@TunaStreetTest) with original commentary.

This is a new optional module — installable by build argument — that layers on top of the existing RAG + Whisper infrastructure without touching it.

---

## Pipeline Overview

```
Twitch/Kick APIs
      │
      ▼
NiFi: FetchClips (Flow 1)
  GetTopStreamers → GetClips → DownloadClip → metadata JSON
      │
      ▼
Kafka: new_clips
      │
      ▼
NiFi: ProcessClips (Flow 2)
  Transcribe (→ whisper-service:8001) + Caption (→ vllm-service:8000) + FFmpeg trim
      │
      ▼
Kafka: processed_clips
      │
      ▼
CSO Operator App: Streamers Page (Review UI)
  Watch clip → Edit caption → Add commentary → Approve
      │
      ▼
NiFi: PublishClip (Flow 3)
  HandleHttpRequest → X Media Upload → X Tweet Create
```

All three NiFi flows live under a new `StreamersApp` parent process group — separate from the existing `CSOOperatorApp` PG so neither breaks the other.

---

## How It Fits into the Existing Stack

The Streamers module reuses what is already running. No new AI services are needed:

| Existing Service | Streamers Use |
|---|---|
| `whisper-service:8001` | Transcribe clip audio (`/transcribe` endpoint) |
| `vllm-service:8000` | Generate short commentary / hot-take caption |
| Kafka (CSM / Strimzi) | Two new topics: `new_clips`, `processed_clips` |
| NiFi (CFM) | Three new process groups under `StreamersApp` PG |
| Qdrant | Optional: index transcripts into `my-rag-collection` so the RAG Query tab can answer questions about past clips |

What IS new:
- Twitch API credentials (Client ID + Secret) in a Kubernetes Secret
- Optional X API credentials for publishing
- A PVC for clip video file storage (reuse existing PVC patterns from `ClouderaStreamingOperators/`)
- New `streamers/` directory in the app repo with flow JSONs + config

---

## Build Argument: Making Streamers Optional

The Streamers module is off by default. It is enabled at build time:

```bash
# Build with Streamers module included
make build MODULES=streamers

# Or via Docker directly
docker build --build-arg MODULES=streamers -t cso-operator-app:latest .

# Build with Streamers + GPU stack
make build STACK=gpu MODULES=streamers

# Full bootstrap (deploys Kafka topics + imports NiFi flows)
make bootstrap MODULES=streamers
```

**How the flag works:**

```
Dockerfile ARG MODULES=''
  → scripts/build-modules.py reads MODULES
  → copies streamers/ into image if "streamers" in list
  → writes modules.json manifest
  → VITE_MODULES=streamers baked into React bundle

Backend reads modules.json at startup:
  → registers /api/streamers/* routes only if streamers is enabled
  → skips otherwise (routes simply don't exist)

Frontend reads VITE_MODULES:
  → renders Streamers nav tab only if enabled
```

ConfigMap gets new keys when the module is enabled:

```yaml
TWITCH_CLIENT_ID: "<from secret>"
TWITCH_CLIENT_SECRET: "<from secret>"
X_BEARER_TOKEN: "<from secret>"
STREAMERS_WATCH_LIST: "xQc,Nickmercs,summit1g"   # comma-separated Twitch logins
CLIP_STORAGE_PATH: "/clips"                        # mounted PVC path
NEW_CLIPS_TOPIC: "new_clips"
PROCESSED_CLIPS_TOPIC: "processed_clips"
```

---

## App: Streamers Page

New tab in the CSO Operator App nav. Three sections:

### Section 1 — Pipeline Status

Shows the three NiFi flows for this module with start/stop controls (same pattern as existing NiFi Controls):

| Flow | Status | Action |
|---|---|---|
| FetchClips | RUNNING | Stop |
| ProcessClips | RUNNING | Stop |
| PublishClip | STOPPED | Start |

Live Kafka depth for `new_clips` and `processed_clips` — same depth/lag widget already used by the Kafka Activity panel.

### Section 2 — Clip Review Queue

Reads from `processed_clips` topic (or a lightweight SQLite/PVC-backed queue if Kafka retention isn't long enough for review lag).

Each card in the queue shows:
- Clip thumbnail (extracted frame via FFmpeg)
- Streamer name + clip title + duration
- Whisper transcript (collapsible)
- vLLM-generated caption (editable text field)
- "Add my commentary" text field
- **Approve → Publish** button (triggers NiFi `PublishClip` via `POST /api/streamers/publish`)
- **Skip** button (marks processed, removes from queue)

### Section 3 — Watch List Config

Simple table to add/remove Twitch logins from `STREAMERS_WATCH_LIST`. Changes write back to the ConfigMap. Restart not required — the NiFi `FetchClips` flow reads the list from a flow attribute via `GenerateFlowFile` + `ReplaceText` pattern.

---

## NiFi Flows (Three New Process Groups)

All three live inside a parent PG named `StreamersApp` — importable as `streamers/StreamersApp.json`.

### Flow 1: FetchClips

```
GenerateFlowFile (scheduled: 15 min)
  → InvokeHTTP (Twitch OAuth token refresh)
  → SplitText (one line per streamer login)
  → InvokeHTTP GET /clips?broadcaster_id=...&first=5
  → EvaluateJsonPath (extract clip id, title, url, thumbnail_url)
  → RouteOnAttribute (skip clip_ids already seen — DistributedMapCache dedupe)
  → InvokeHTTP (download MP4 → PutFile to /clips/<id>.mp4)
  → ReplaceText (build metadata JSON)
  → PublishKafka_2_6 → new_clips
```

Rate limit: `ControlRate` processor caps to 50 calls/min — well under Twitch's 800-point budget.

### Flow 2: ProcessClips

```
ConsumeKafka_2_6 ← new_clips
  → InvokeHTTP POST whisper-service:8001/transcribe (multipart file=@/clips/<id>.mp4)
  → EvaluateJsonPath $.text → transcript attribute
  → InvokeHTTP POST vllm-service:8000/v1/chat/completions
      (prompt: "Write a short witty hot-take about this clip: {transcript}")
  → EvaluateJsonPath $.choices[0].message.content → caption attribute
  → MergeContent (combine original metadata + transcript + caption → enriched JSON)
  → PublishKafka_2_6 → processed_clips
```

FFmpeg trim (phase 2): `ExecuteStreamCommand` after Whisper to cut to highlight segment based on transcript timestamps.

### Flow 3: PublishClip

```
HandleHttpRequest (triggered by Approve button → POST /contentListener)
  → EvaluateJsonPath (clip path, tweet text from request body)
  → InvokeHTTP POST api.twitter.com/2/media/upload (chunked, multipart)
  → EvaluateJsonPath $.media_id_string
  → InvokeHTTP POST api.twitter.com/2/tweets
      body: {"text": "...", "media": {"media_ids": ["<id>"]}}
  → HandleHttpResponse (200 back to app)
```

---

## Repo Changes (cso-operator-app)

```
cso-operator-app/
├── streamers/
│   ├── StreamersApp.json          # parent PG export (all 3 flows)
│   ├── config.yaml                # module metadata
│   └── pvc.yaml                   # clip storage PVC
├── backend/
│   ├── routers/
│   │   └── streamers.py           # new: /api/streamers/*
│   └── services/
│       └── streamers.py           # Twitch API client, clip queue, X publisher
├── frontend/
│   └── src/
│       ├── pages/
│       │   └── Streamers.tsx      # new page
│       └── components/
│           └── ClipCard.tsx       # review queue card
├── scripts/
│   └── build-modules.py           # reads MODULES arg, writes modules.json
└── Makefile                       # add MODULES= to build/bootstrap targets
```

---

## Decisions

| Question | Decision |
|---|---|
| Kick support | **Later** — Twitch only for phase 1 |
| Clip storage | **PVC** — persistent `/clips` mount, survives restarts |
| Review queue | **Kafka retention 7 days** — `processed_clips` topic retention annotation |
| X publishing | **Manual only** — Approve button in UI; auto-post is a future phase |
| X API account | **X Premium on @TunaStreetTest** — no API tier limits blocking us |

---

## Implementation Order

Each phase ends with commit + push to both `cso-operator-app` and `DesktopShare`.

| Phase | Work | Agents |
|---|---|---|
| 1 | `streamers/` dir + `config.yaml` + `build-modules.py` + Makefile MODULES arg | Solo |
| 2a | Backend `streamers.py` router + Twitch API client | Parallel |
| 2b | Dockerfile `ARG MODULES` + Vite env wiring | Parallel |
| 3 | NiFi `FetchClips` flow JSON + test fetch into `new_clips` | Solo |
| 4 | NiFi `ProcessClips` flow JSON + test `processed_clips` output | Solo |
| 5a | Frontend `Streamers.tsx` — pipeline status + review queue | Parallel |
| 5b | Backend `/api/streamers/*` endpoints (queue read + publish trigger) | Parallel |
| 6 | NiFi `PublishClip` flow JSON + X API integration | Solo |
| 7 | PVC for clip storage + Kafka topic retention config | Solo |
| 8 | Update `cso-operator-app-plan.md`, `cso-operator-app-windows-test-plan.md`, `ai-sources.md` | Solo |

---

## What Was Actually Built (vs Plan)

The NiFi flows turned out simpler than the original design. Rather than NiFi doing the Twitch API calls and file downloads directly, the actual implementation uses:

- **FetchClips**: GenerateFlowFile (15 min timer) → InvokeHTTP `POST /api/streamers/fetch-clips` (all Twitch GQL + download logic in Python)
- **ProcessClips**: ConsumeKafka_2_6 ← new_clips → InvokeHTTP `POST /api/streamers/process-clip` → PublishKafka_2_6 → processed_clips
- **PublishClip**: HandleHttpRequest (9001) → InvokeHTTP → HandleHttpResponse

The backend service (`backend/services/streamers.py`) does all the heavy lifting: Twitch GQL for signed CloudFront URLs, aiokafka manual partition assignment, Whisper + vLLM calls, tweepy OAuth1 + chunked media upload + v2 create_tweet.

## Key Technical Lessons

| Issue | Fix |
|---|---|
| Twitch CDN changed in 2024 — thumbnail→.mp4 trick dead | Use GQL `VideoAccessToken_Clip` query → `sourceURL?sig=&token=` |
| aiokafka hangs after manual `seek()` with `async for` | Use `getmany(tp, timeout_ms=5000)` one-shot fetch |
| Strimzi created 1 partition despite spec saying 3 | Hardcode `TopicPartition(topic, 0)` |
| X API v1.1 `update_status` retired | tweepy v2 `create_tweet` + v1 `media_upload(chunked=True)` |
| X API 402 "no credits" | Pay-per-use billing — add credits at developer.x.com |
| `vite-env.d.ts` caught by `.gitignore` | Add `!frontend/src/vite-env.d.ts` negation |

## What's Next

### High Priority (next session)

- **ProcessClips refactor** — move Whisper + vLLM out of the Python backend into NiFi-native InvokeHTTP processors. Current architecture routes everything through the app backend which blocks NiFi's InvokeHTTP and causes timeouts on 45-60s clips. Existing RAG NiFi flows already do Whisper + vLLM — reuse that pattern.

### Later

- **Publish history tab** — show past published clips with tweet URLs, timestamps, and captions (`.published.json` already written, just needs a UI)
- **Kick support** — credentials set (`KICK_CLIENT_ID`, `KICK_CLIENT_SECRET`), API integration not yet implemented in `fetch_clips`
- **Auto-publish mode** — bypass review UI and post top clips automatically on a schedule
- **Streamer X handle mapping** — watchlist enhancement to store each streamer's X handle alongside Twitch login for credit tagging in tweets

## Session 2 Additions (2026-06-28)

Beyond the initial scaffold, this session added:

| Feature | Details |
|---|---|
| Kafka topic panels | Live message count + last 5 records for `new_clips` and `processed_clips` in the Streamers UI |
| Reset Kafka button | Deletes topics via Kafka Admin API (not Strimzi CRDs — those don't work reliably), wipes `/clips/*.mp4`, resets `.seen_clips.json` |
| Dismiss on publish | Cards vanish after 1.2s "Posted ✓" flash; Refresh clears stale dismissed state |
| Fallback captions | 5 rotating Tuna Street fallbacks when vLLM returns empty |
| Duration filter | Fetch 20 clips per streamer, drop < 45s, sort longest-first, cap at 3 per streamer |
| File-exists gate | Review queue only surfaces clips whose MP4 is on disk — no partial/stale cards |
| 404 on missing file | Publish endpoint returns actionable 404 instead of opaque 502 when file is gone |
| RBAC | Added `kafkatopics get/list/delete` to `cso-operator-app-writer` role in `cld-streaming` namespace |

## Session 3 Additions (2026-06-29)

### Performance fixes

| Change | Details |
|---|---|
| NiFi group ID cache | `_resolve_streamer_groups` BFS result cached 5 min — was running on every `/flows` poll (12×/min) |
| Parallel Kafka consumers | `topic_stats` runs both consumers concurrently via `asyncio.gather` — halves wall time (~20s → ~10s) |
| topic_stats result cache | 30s TTL — repeated Refresh clicks don't spin new consumers |
| Flow poll 5s → 30s | Frontend poll interval reduced 6× |
| Topics not auto-loaded | Kafka consumer lifecycle now only triggered by manual Refresh button |
| Page-visibility pause | Poll stops when browser tab is hidden, resumes immediately when tab regains focus |
| Lazy thumbnails | `loading="lazy"` on clip thumbnail images |

### Feature additions

| Feature | Details |
|---|---|
| Skip persistence | Skip button calls `POST /api/streamers/skip` → writes clip_id to `/clips/.skipped.json`; skipped clips filtered from queue on next load |
| Publish persistence | `publish_clip` writes clip_id to `/clips/.published.json` on successful tweet; published clips filtered from queue |
| Reset clears skip+publish | `Reset Kafka` button now also wipes `.skipped.json` and `.published.json` |
| Video player in review | `<video controls preload="none">` in each ClipCard served via `GET /api/streamers/clip/{clip_id}` — `preload="none"` prevents simultaneous buffering of all queued clips |
| Clips per run reduced | 3 per streamer → 2 per streamer — fewer downloads, less Whisper load per cycle |

### Idle service scale-down (kubectl)

To free CPU/memory on the cluster while not using EFM, MiNiFi, SSB, or Schema Registry:

```bash
# Scale down — run these yourself; bring back up with --replicas=1 when needed
kubectl scale deploy efm             -n cld-streaming --replicas=0
kubectl scale deploy ssb-mve         -n cld-streaming --replicas=0
kubectl scale deploy ssb-sse         -n cld-streaming --replicas=0
kubectl scale deploy schema-registry -n cld-streaming --replicas=0

# MiNiFi is a bare Pod — delete it (re-create from ClouderaStreamingOperators/minifi-agent-pod.yaml)
kubectl delete pod minifi-agent-k8s -n cld-streaming

# Keep these running:
# ssb-postgresql  — EFM + Schema Registry store config here; needed to restore them cleanly
# All CSO Operator App services, NiFi, Kafka, Whisper, vLLM, Qdrant
```

To restore:
```bash
kubectl scale deploy efm             -n cld-streaming --replicas=1
kubectl scale deploy ssb-mve         -n cld-streaming --replicas=1
kubectl scale deploy ssb-sse         -n cld-streaming --replicas=1
kubectl scale deploy schema-registry -n cld-streaming --replicas=1
kubectl apply -f ~/ClouderaStreamingOperators/minifi-agent-pod.yaml
```

### Deploy reference (full install)

```bash
cd ~/cso-operator-app
make deploy MODULES=efm,rag,streamers
```

After any deploy that resets credentials (e.g. first deploy on a new machine):
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
