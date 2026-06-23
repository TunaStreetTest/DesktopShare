# CSO Operator App — Plan

A single demo app that exercises every concept from the **RAG with Cloudera Streaming Operators** and **Insanely Fast Audio Transcription with Cloudera Streaming Operators** posts: ingest documents, ingest audio, watch Kafka move it, search Qdrant, ask vLLM, and drive NiFi flows from one screen.

Supersedes `rag-app-plan.md` (RAG-only scope). Local demo only — no auth, no production hardening.

> **Status:** end-to-end working on Mac and Windows Minikube. Living spec — keep in root while we iterate. Companion test plan: [`cso-operator-app-windows-test-plan.md`](cso-operator-app-windows-test-plan.md).

## Source posts (canonical)

- **RAG with Cloudera Streaming Operators** — `cldr-steven-matison.github.io/_posts/2026-03-22-RAG with Cloudera Streaming Operators.md`
  - vLLM (Qwen2.5-3B-Instruct), Qdrant (`my-rag-collection`, 768-d Cosine), TEI embedding (nomic-embed-text-v1), NiFi flows `IngestDataToStream` (doc path) + `StreamTovLLM`, Kafka topic `new_documents`.
- **Insanely Fast Audio Transcription with Cloudera Streaming Operators** — `cldr-steven-matison.github.io/_posts/2026-03-30-Audio Transcription with Cloudera Streaming Operators.md`
  - Whisper-large-v3 + Flash Attention 2 wrapped in FastAPI on `:8001`, NiFi flows `IngestDataToStream` (audio in) + `StreamToWhisper` (transcribe), Kafka topic `new_audio`. Transcripts are republished into `new_documents` so the existing RAG pipeline picks them up unchanged.

Reference repos:
- `~/Documents/GitHub/ClouderaStreamingOperators/` — all backing-service YAMLs
- `~/Documents/GitHub/NiFi-Templates/` — exported NiFi flow definitions
- `~/Documents/GitHub/DesktopShare/files/` — working copies of flows + helper scripts

`ai-sources.md` is the index for these.

## Scope

- **Build/dev**: MacBook (Minikube + GPU passthrough already running).
- **Target deploy**: Windows desktop (Minikube + RTX 4060 + GPU passthrough). Same `kubectl apply` works on both.
- **Repo**: new `cso-operator-app` (separate from DesktopShare).

## Backing stack — exact details from sources

All YAMLs live in `~/Documents/GitHub/ClouderaStreamingOperators/`. The new app's `k8s/backing/` folder will copy these in so the repo is self-contained.

### Namespaces
- `cld-streaming` — CSM (Kafka via Strimzi), CSA (Flink) operators
- `cfm-streaming` — CFM (NiFi) operator
- `default` — vLLM, Qdrant, embedding-server, whisper-server, the new app

### vLLM (`vllm-Qwen2.5-3B-Instruct.yaml`)

Deployment: `vllm-server` → Service: `vllm-service.default:8000`
Image: `vllm/vllm-openai:latest`
Currently serving **`Qwen/Qwen2.5-1.5B-Instruct`** (the YAML is named after the original 3B target; 1.5B is what's loaded on the validated Windows cluster). The backend's `VLLM_MODEL` must match what `GET /v1/models` reports — `/api/health` validates this and `HealthBar` surfaces a mismatch as a red dot with the expected vs loaded names in the tooltip.

Endpoint used by app: `POST /v1/chat/completions` (OpenAI-compatible). The backend currently does a **non-streaming** chat completion and re-emits the answer as a single SSE delta — see `Backend endpoints → /api/query`.

### Qdrant (`qdrant-deployment.yaml`)

Deployment: `qdrant` → Service: `qdrant.default:6333` (HTTP), `:6334` (gRPC). emptyDir storage.
Collection (created by app on first run if missing):
```
PUT /collections/my-rag-collection
{"vectors": {"size": 768, "distance": "Cosine"}}
```

### Embedding server (`embedding-server.yaml`)

Deployment: `embedding-server` (TEI image `ghcr.io/huggingface/text-embeddings-inference:cpu-1.5`)
Service: `embedding-server-service.default:80` (in-cluster) — port-forwarded to `localhost:8080` for Mac dev.
Model: `nomic-ai/nomic-embed-text-v1` (768-d). `--hf-api-token` injected via launch args.
Endpoint: `POST /embed` — body `{"inputs": "..."}` returns `[[float, float, ...]]`.

### Whisper server

Owned by this app. Lives in `cso-operator-app/whisper/`. Two artifacts:

#### `Dockerfile.whisper`
```dockerfile
# Dockerfile.whisper.12 - Final Stable "G1" Build
# Targets: CUDA 12.4, Flash Attention 2, Whisper-Large-v3

FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04 AS builder

ARG HF_TOKEN
ENV HF_TOKEN=${HF_TOKEN}
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3.11 python3.11-venv python3-pip git ffmpeg ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN python3.11 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

RUN pip install --no-cache-dir --upgrade pip setuptools wheel packaging

RUN pip install --no-cache-dir \
    torch==2.4.1+cu124 torchvision==0.19.1+cu124 torchaudio==2.4.1+cu124 \
    --extra-index-url https://download.pytorch.org/whl/cu124

RUN pip install --no-cache-dir \
    fastapi uvicorn starlette pydantic pydantic-core \
    anyio idna sniffio typing-extensions click h11 python-multipart

RUN pip install --no-cache-dir --no-deps \
    transformers insanely-fast-whisper==0.0.15 huggingface_hub

RUN pip install --no-cache-dir \
    pyyaml requests tqdm numpy regex sentencepiece \
    httpx filelock fsspec safetensors accelerate \
    soundfile librosa scipy tokenizers

RUN pip install --no-cache-dir flash-attn --no-build-isolation

RUN python3 -c "from transformers import pipeline; pipeline('automatic-speech-recognition', model='openai/whisper-large-v3')"

# STAGE 2
FROM nvidia/cuda:12.4.1-cudnn-devel-ubuntu22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y python3.11 ffmpeg && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /root/.cache/huggingface /root/.cache/huggingface
ENV PATH="/opt/venv/bin:$PATH"

COPY <<EOF /app/main.py
from fastapi import FastAPI, File, UploadFile
from fastapi.responses import JSONResponse
import torch
from transformers import pipeline
import tempfile, os

app = FastAPI(title="StreamToWhisper")

pipe = pipeline(
    "automatic-speech-recognition",
    model="openai/whisper-large-v3",
    torch_dtype=torch.float16,
    device="cuda:0",
    model_kwargs={"attn_implementation": "flash_attention_2"}
)

@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    with tempfile.NamedTemporaryFile(delete=False, suffix=".wav") as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name
    try:
        result = pipe(tmp_path, chunk_length_s=30, batch_size=24, return_timestamps=True)
        os.unlink(tmp_path)
        return {"text": result["text"]}
    except Exception as e:
        return JSONResponse(status_code=500, content={"error": str(e)})

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8001)
EOF

EXPOSE 8001
ENTRYPOINT ["/opt/venv/bin/python3", "main.py"]
```

Build:
```bash
eval $(minikube docker-env)
docker build -t streamwhisper:latest --build-arg HF_TOKEN=$MY_TOKEN -f Dockerfile.whisper .
```

#### `whisper-server.yaml`
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whisper-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: whisper-server
  template:
    metadata:
      labels:
        app: whisper-server
    spec:
      containers:
      - name: whisper-server
        image: streamwhisper:latest
        imagePullPolicy: Never
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: "8Gi"
        ports:
        - containerPort: 8001
---
apiVersion: v1
kind: Service
metadata:
  name: whisper-service
spec:
  selector:
    app: whisper-server
  ports:
  - protocol: TCP
    port: 8001
    targetPort: 8001
  type: ClusterIP
```

Endpoint used by NiFi: `POST whisper-service:8001/transcribe` (multipart `file=@...`) → `{"text": "..."}`.

### Kafka (CSM / Strimzi, namespace `cld-streaming`)

Topics the app reads / writes:

| Topic | Producer | Consumer | Payload |
|---|---|---|---|
| `new_audio` | NiFi `IngestDataToStream` (audio path) | NiFi `StreamToWhisper` | raw audio bytes |
| `new_documents` | NiFi `IngestDataToStream` (doc path) *and* `StreamToWhisper` | NiFi `StreamTovLLM` | text |

In-cluster bootstrap: `my-cluster-kafka-bootstrap.cld-streaming.svc:9092`. App uses `aiokafka` for topic stats, tail, and producing into `new_*` topics on ingest.

For host-side dev (Mac/Windows), the Kafka CR has an additional `external` listener (`type: loadbalancer`, `port: 9094`, plaintext) with per-broker `advertisedHost: localhost` and unique `advertisedPort: 19094-19096`. Four port-forwards map bootstrap (`localhost:19090`) and brokers 0/1/2 (`localhost:19094`/`19095`/`19096`) to the LB services. `scripts/kafka-external-listener.sh` patches the Kafka CR idempotently; `scripts/mac-dev.sh` starts the port-forwards.

There is no separate transcript topic — Whisper republishes into `new_documents` so the existing RAG flow handles transcripts unchanged.

### NiFi (CFM, namespace `cfm-streaming`)

UI (in-cluster): `https://mynifi-web.mynifi.cfm-streaming.svc.cluster.local/nifi/`
REST: same host. Auth: Bearer token via `POST /nifi-api/access/token`. Admin credentials are in `Secret/nifi-admin-creds` (keys `username`, `password`) in `cfm-streaming`. Backend caches the token and refreshes on 401. The shared httpx client must keep cookies cleared on NiFi calls — when both the Bearer and a session cookie (`INGRESSCOOKIE` / `__Secure-Request-Token`) are present on a write, NiFi falls into cookie-auth mode and rejects with 403/CSRF.

All three flows are imported under a single parent process group (`CSOOperatorApp`) for one-click drag-and-drop. The resolver BFS-walks PGs from root to find them by name.

Process groups (shipped as one JSON in `flows/CSOOperatorApp.json`):

| Flow | Role | Inputs | Outputs |
|---|---|---|---|
| `IngestDataToStream` | Unified ingest (docs + audio) | Single `ListenHTTP` on `:9000/contentListener` | `RouteOnAttribute` on `mime.type` → `new_documents` (docs) / `new_audio` (audio) |
| `StreamToWhisper` | Transcribe | `ConsumeKafka_2_6 new_audio` | `InvokeHTTP whisper-service:8001/transcribe` → `EvaluateJsonPath $.text` → `ReplaceText` → `PublishKafka_2_6 new_documents` |
| `StreamTovLLM` | RAG indexer | `ConsumeKafka_2_6 new_documents` | `SplitText` (20-line) → `ExtractText` → `ReplaceText` (embed JSON) → `InvokeHTTP embed` → `EvaluateJsonPath` → `ReplaceText` (Qdrant upsert) → `InvokeHTTP qdrant upsert` |

The backend posts every upload — doc or audio — to `http://mynifi.cfm-streaming.svc.cluster.local:9000/contentListener` with the resolved `Content-Type` so `RouteOnAttribute` can branch. There is no per-type endpoint and no `aiokafka` direct-publish fallback; failures bubble up as a 502 from `/api/ingest` so they're visible in the UI status line.

When CFM ships flow CRs, JSON import is replaced with declarative CRs. Backend is unaffected since it speaks NiFi REST.

## App architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  React + Vite + TS + Tailwind + shadcn/ui  (single page)             │
│  ┌──────────┬──────────┬──────────┬──────────┬─────────────────────┐ │
│  │ Demo     │ Ingest   │ NiFi     │ Kafka    │ RAG Query (chat)    │ │
│  │ Mode     │ (upload) │ Controls │ Activity │ + sources reveal    │ │
│  └──────────┴──────────┴──────────┴──────────┴─────────────────────┘ │
│                       Health bar across the top                      │
└──────────────────────────────────────────────────────────────────────┘
                                  │ /api/*
┌──────────────────────────────────────────────────────────────────────┐
│  FastAPI backend (proxy + RAG orchestrator)                          │
│  /api/query   /api/ingest/{doc,audio}   /api/health                  │
│  /api/nifi/*  /api/qdrant/*             /api/kafka/*                 │
└──────────────────────────────────────────────────────────────────────┘
   │            │             │              │              │
   ▼            ▼             ▼              ▼              ▼
 vllm        qdrant      embedding-      NiFi REST       Kafka
 :8000       :6333       server:80       cfm-streaming   (aiokafka)
 (Qwen2.5    (768-d      (TEI nomic                       new_audio,
  -3B)        Cosine)     -embed)                         new_documents

 whisper-service:8001 (insanely-fast-whisper, large-v3, GPU)
```

## Backend endpoints

| Endpoint | Action |
|---|---|
| `POST /api/query` | Embed → Qdrant top-k → build prompt (chunks capped at 500 chars, vector-leakage chunks dropped) → vLLM **non-streaming** chat completion → re-emit as one OpenAI-style SSE delta + `[DONE]`. On non-2xx vLLM responses, emit `event: error` with the body so the UI can show it instead of hanging. Mirrors the blog's working `query-rag-5.py` request shape. |
| `POST /api/ingest` | Single multipart upload endpoint. Forwards the file body to `NIFI_INGEST_URL` (default `http://mynifi.cfm-streaming.svc.cluster.local:9000/contentListener`) with the resolved `Content-Type`; NiFi's `RouteOnAttribute` branches docs vs audio. Returns NiFi's status + first 500 bytes of body so the UI can surface real failures. |
| `GET  /api/sample-audio` | Streams the blog's reference WAV through the backend so the browser doesn't hit upstream CORS. |
| `GET  /api/nifi/state` | State of the 3 process groups |
| `POST /api/nifi/{name}/start\|stop` | Toggle by name (resolved to UUID + revision at startup) |
| `GET  /api/qdrant/stats` | Point count, segments |
| `POST /api/qdrant/recreate` | Drop + recreate `my-rag-collection` (768-d Cosine) |
| `GET  /api/kafka/topics` | Depth for the watched topics (`new_audio`, `new_documents`) |
| `GET  /api/kafka/all-topics` | Depth + partitions for every non-internal topic |
| `GET  /api/kafka/tail/{topic}` | SSE tail of recent messages |
| `GET  /api/kafka/peek/{topic}?limit=10` | Last N messages on any topic, newest-first. UTF-8 payload preview with a `payload_b64` fallback for binary topics like `new_audio`. Click-to-expand surface for the All Topics grid. |
| `GET  /api/k8s/operators` | CSM/CSA/CFM operator presence — looks up `strimzi-cluster-operator`, `flink-kubernetes-operator`, `cfm-operator` and counts CRDs in their owned API groups. |
| `GET  /api/k8s/pods` | Pod summary for `cld-streaming`, `cfm-streaming`, `default` — phase counts plus per-pod phase/ready/restarts/age/node/owner. |
| `POST /api/k8s/deploy/{ns}/{name}/restart` | `kubectl rollout restart`-equivalent annotation patch. Namespace whitelisted to the three watched namespaces. |
| `DELETE /api/k8s/pod/{ns}/{name}` | Delete a single pod with default grace period. Same namespace whitelist. |
| `GET  /api/health` | Pings every backing service. The `vllm` entry parses `/v1/models` and fails the service if `VLLM_MODEL` is not loaded — returns `configured` + `loaded` so a misconfigured name shows up in the HealthBar tooltip. |

**Stack**: FastAPI, `httpx.AsyncClient` (vLLM/Qdrant/embedding/NiFi/Whisper), `aiokafka` (topic stats + tail), Pydantic settings from ConfigMap/env.

**NiFi process-group resolution**: at startup, GET `/process-groups/root/process-groups` → cache `{name: (id, revision)}`. State changes use `PUT /flow/process-groups/{id}` with `{"id": "...", "state": "RUNNING|STOPPED"}` and the cached revision (refreshed on 409).

## Frontend panels

- **Demo Mode** — guided 4-step walkthrough:
  1. Start the three flows
  2. Drop a doc *or* audio file (or click "use sample" → blog test WAV `OSR_us_000_0010_8k.wav`)
  3. Watch the relevant Kafka topic light up
  4. Ask a pre-baked question (`What is StreamToVLLM?` for docs, `How is rice prepared?` for the sample audio) and stream the answer
- **Ingest** — dropzone with format detection. Both paths feed `IngestDataToStream` (audio → `new_audio`, doc → `new_documents`).
- **NiFi Controls** — three cards: `IngestDataToStream`, `StreamToWhisper`, `StreamTovLLM`. Start/stop with optimistic STARTING…/STOPPING… badge, live state polled every 4s.
- **Kafka Activity** — live tail of `new_audio` (binary preview/length) and `new_documents` (text). Depth/lag indicators per topic.
- **All Topics** (bottom of page) — live grid of every non-internal topic with partition count and depth, with `new_audio`/`new_documents` highlighted. **Click any tile to peek the last 10 messages** (auto-refreshing every 5s) — used for spot-checking Whisper transcripts landing in `new_documents` without resetting the SSE tail.
- **Cloudera Operators** — three rows (CSM/Strimzi, CSA/Flink, CFM) showing ready/replicas, image, version, and CRD-presence count. Polls every 15s.
- **Pods** — namespace-grouped view of `cld-streaming`, `cfm-streaming`, `default` with phase, ready, restarts, age, node, and **rollout-restart / delete-pod** actions per row (5s refresh, inline confirm on delete).
- **RAG Query** — chat UI with vLLM streaming, expandable source chunks (Qdrant payloads), prompt history.
- **Health bar** — green/red dots per backing service, click for details.

State: React hooks. Streaming: `EventSource` for SSE. UI primitives: shadcn Button/Card/Toast/Dialog/Tabs.

## Repo layout (`cso-operator-app`)

```
cso-operator-app/
├── README.md
├── Dockerfile                    # multi-stage: vite frontend → python backend
├── backend/
│   ├── main.py
│   ├── routers/  (query.py, ingest.py, nifi.py, qdrant.py, kafka.py, health.py)
│   ├── services/ (vllm.py, qdrant.py, embedding.py, whisper.py, nifi.py, kafka.py)
│   ├── config.py
│   └── requirements.txt
├── frontend/
│   ├── src/  (components/, pages/, api/, hooks/, types.ts)
│   ├── vite.config.ts, tailwind.config.ts, package.json
├── whisper/
│   ├── Dockerfile.whisper        # full Dockerfile from audio post
│   └── whisper-server.yaml
├── flows/                        # exported NiFi process groups (single ListenHTTP entry)
│   └── CSOOperatorApp.json       # parent PG bundling IngestDataToStream + StreamToWhisper + StreamTovLLM
├── k8s/
│   ├── deployment.yaml           # the app itself (uses cso-operator-app SA)
│   ├── service.yaml              # NodePort 30080
│   ├── configmap.yaml            # all backing service URLs/ports + NIFI_INGEST_URL + VLLM_MODEL
│   ├── rbac.yaml                 # ServiceAccount + cluster-wide reader + per-ns writer (cld-streaming, cfm-streaming, default)
│   └── backing/                  # copies from ClouderaStreamingOperators
│       ├── vllm-Qwen2.5-3B-Instruct.yaml
│       ├── qdrant-deployment.yaml
│       └── embedding-server.yaml
├── samples/
│   ├── OSR_us_000_0010_8k.wav    # blog reference audio
│   └── streamtovllm.md           # blog reference doc
├── scripts/                      # baked into the runtime image
│   ├── diagnose-query.py         # in-pod probe of env, vLLM, /api/health, /api/query SSE body
│   ├── mac-dev.sh                # port-forwards + uvicorn + vite
│   ├── deploy.sh                 # minikube image build + kubectl apply
│   ├── bootstrap-stack.sh        # apply backing/, build whisper image, import flows
│   └── kafka-external-listener.sh
└── Makefile
```

## Build / deploy

**Image strategy**: local-only, no registry push. Identical command on Mac and Windows:

```bash
# Mac and Windows, identical
eval $(minikube docker-env)
docker build -t cso-operator-app:latest .
kubectl apply -f k8s/
minikube service cso-operator-app
```

The app Dockerfile is multi-stage: Node builds the React bundle, slim Python image serves FastAPI + the static bundle from `/app/static`.

**ConfigMap** (`k8s/configmap.yaml`) drives every URL so the same image runs on Mac and Windows:

```yaml
data:
  VLLM_URL: "http://vllm-service.default.svc.cluster.local:8000"
  VLLM_MODEL: "Qwen/Qwen2.5-1.5B-Instruct"   # must match GET /v1/models
  QDRANT_URL: "http://qdrant.default.svc.cluster.local:6333"
  EMBED_URL: "http://embedding-server-service.default.svc.cluster.local:80"
  WHISPER_URL: "http://whisper-service.default.svc.cluster.local:8001"
  NIFI_URL: "https://mynifi-web.cfm-streaming.svc.cluster.local"
  NIFI_INGEST_URL: "http://mynifi.cfm-streaming.svc.cluster.local:9000/contentListener"
  KAFKA_BOOTSTRAP: "my-cluster-kafka-bootstrap.cld-streaming.svc:9092"
  QDRANT_COLLECTION: "my-rag-collection"
  EMBED_DIM: "768"
  TOPIC_AUDIO: "new_audio"
  TOPIC_DOCS: "new_documents"
```

For Mac dev, `.env.local` overrides with `localhost` ports (8080 for embedding via port-forward, 8000/6333/8001 for the rest).

> **Gotcha:** `kubectl set env deploy/cso-operator-app VLLM_MODEL=...` on the deployment **shadows** the ConfigMap. If `/api/health` reports a model mismatch even after applying a fresh ConfigMap, clear the override:
>
> ```bash
> kubectl set env deploy/cso-operator-app VLLM_MODEL-
> kubectl rollout restart deploy/cso-operator-app
> ```

## Mac dev workflow

```bash
# terminal 1: kubectl port-forwards
kubectl port-forward svc/vllm-service 8000:8000 &
kubectl port-forward svc/qdrant 6333:6333 &
kubectl port-forward svc/embedding-server-service 8080:80 &
kubectl port-forward svc/whisper-service 8001:8001 &
# NiFi via service or ingress depending on how it's exposed

# terminal 2: backend
cd backend && uvicorn main:app --reload

# terminal 3: frontend (proxies /api → :8000)
cd frontend && npm run dev
```

## Implementation order

All ten phases are done. Kept here for the historical narrative; current behavior is documented above.

1. ✅ **Repo scaffold** + README + Makefile + ConfigMap.
2. ✅ **Backend skeleton** + `/api/health` (proves connectivity to all five services). Later upgraded to validate `VLLM_MODEL` against `/v1/models`.
3. ✅ **Query path** end-to-end. Originally streaming pass-through; reworked to mirror the blog's working `query-rag-5.py` (non-streaming POST) with errors surfaced as `event: error`.
4. ✅ **NiFi controls** — name→UUID resolution, start/stop, state.
5. ✅ **Qdrant management** — recreate, stats.
6. ✅ **Kafka activity** — topics endpoint, then SSE tail with `aiokafka`.
7. ✅ **Ingest** — collapsed to a single `ListenHTTP` at `:9000/contentListener` with `RouteOnAttribute` branching by mime type. Backend has one `/api/ingest`; the doc/audio split was removed. `/api/sample-audio` proxies the blog WAV to dodge browser CORS.
8. ✅ **Frontend polish** — Demo Mode, health bar with mismatch tooltips, source-chunk reveal, visible SSE error panel.
9. ✅ **Containerize** + deploy on Mac Minikube. `scripts/` baked into the image so `diagnose-query.py` is one `kubectl exec` away.
10. ✅ **Test on Windows** Minikube — full path validated; gotchas captured in [`cso-operator-app-windows-test-plan.md`](cso-operator-app-windows-test-plan.md).

## CPU variant (Mac, no GPU)

A strict-CPU parallel stack for Mac dev when GPU passthrough isn't available (or isn't worth the setup cost). No Metal, no CUDA — runs on any Mac, including inside a generic Minikube. GPU manifests are untouched; the toggle is `STACK=cpu` on the `make bootstrap` / `make dev` targets. Windows demo path is unaffected.

### What gets swapped

| Service | GPU (default) | CPU (`STACK=cpu`) |
|---|---|---|
| vLLM | `vllm/vllm-openai:latest`, Qwen2.5-3B/1.5B-Instruct on `nvidia.com/gpu` | `ghcr.io/ggml-org/llama.cpp:server`, `Qwen/Qwen2.5-1.5B-Instruct-GGUF:Q4_K_M`, CPU-only |
| Whisper | `streamwhisper:latest` (insanely-fast-whisper + flash-attn + CUDA 12.4, Whisper-large-v3) | `streamwhisper-cpu:latest` (faster-whisper `small`, int8 CTranslate2, no torch) |

Everything else (Qdrant, the TEI embedding server which is already the `cpu-1.5` image, Kafka, NiFi, the app itself) is identical on both paths.

### Files

```
k8s/backing/vllm-cpu.yaml                 # llama.cpp server Deployment + vllm-cpu-service
k8s/backing/vllm-service-cpu-alias.yaml   # alias Service named `vllm-service` selecting CPU pods
whisper/Dockerfile.whisper.cpu            # faster-whisper image
whisper/whisper-server-cpu.yaml           # CPU Whisper Deployment + whisper-cpu-service
whisper/whisper-service-cpu-alias.yaml    # alias Service named `whisper-service` selecting CPU pods
```

### Why aliases

Backend ConfigMap pins `VLLM_URL` to `vllm-service.default.svc.cluster.local` and `WHISPER_URL` to `whisper-service.default.svc.cluster.local`. NiFi's `StreamToWhisper` flow has `whisper-service:8001/transcribe` baked into its `InvokeHTTP`. Rather than re-edit ConfigMap + flow JSON on every stack switch, the CPU bootstrap deletes the GPU Service and applies a same-named alias that selects the CPU deployment. The canonical DNS names stay valid; nothing downstream notices the swap.

The CPU and GPU `-service` siblings (`vllm-cpu-service`, `whisper-cpu-service`) still exist as explicit handles — useful for side-by-side debugging when both stacks happen to be deployed (rare on Mac, where one usually has the RAM for only one).

### Model name alignment

llama.cpp's server returns the loaded GGUF identifier from `GET /v1/models`. The `vllm-cpu.yaml` args pass `--alias Qwen/Qwen2.5-1.5B-Instruct` so the reported name matches the existing `VLLM_MODEL` value in `k8s/configmap.yaml`. HealthBar's mismatch check stays green; no ConfigMap edit needed.

### Usage

```bash
# CPU bootstrap (no $HF_TOKEN needed — Qwen2.5-1.5B-GGUF is public)
make bootstrap STACK=cpu
make dev STACK=cpu          # same port-forwards as GPU
make backend                # unchanged
make frontend               # unchanged

# Switch back to GPU later
export HF_TOKEN=...
make bootstrap STACK=gpu
```

`scripts/bootstrap-stack.sh` is idempotent in both directions — running with the opposite `STACK` removes the previous variant's Deployments/aliases before applying the new ones.

### Performance ceilings (Mac, strict CPU)

- **llama.cpp Qwen2.5-1.5B Q4_K_M**: ~10–20 tok/s on M-series CPU cores (no Metal). First request loads the model into RAM (~1 GB).
- **faster-whisper small int8**: ~5–10× realtime on CPU. The blog sample WAV (`OSR_us_000_0010_8k.wav`, ~30s) transcribes in ~3–6 s after the first warmup request. Cold-start is bounded because the image pre-bakes the model.

These are intentionally demo-tier — the goal is "the same pipeline runs end-to-end with no NVIDIA dependency," not feature parity with the GPU path's `whisper-large-v3` quality.

### Known gaps / future tweaks

- `flows/CSOOperatorApp.json` still embeds the GPU-tuned `chunk_length_s=30, batch_size=24` and `beam_size` defaults via the `InvokeHTTP` URL alone — the server-side faster-whisper params are hard-coded in `Dockerfile.whisper.cpu`'s `main.py`. If we want runtime control, expose them as env vars on the CPU Deployment.
- The CPU Whisper Service alias and GPU Service can't both exist in `default` simultaneously. If a future demo needs side-by-side, scope one of them to a different namespace.

## Open follow-ups

- Decide on 1.5B vs 3B for the demo (currently 1.5B; 3B is the originally specified target and gives better RAG answers).
- Optional: stream tokens as they generate instead of one-shot completion. The current non-streaming path was chosen to match the blog and surface errors cleanly; revisit if perceived latency becomes an issue.
- Optional: bake an "expected models" allowlist into `/api/health` so the misconfig message names what *should* be loaded too.
- Pod actions are scoped to single-pod delete + deployment rollout-restart. Future: scale, edit replicas, drain a node, kafka topic peek with offset selector.

## Out of scope

- **Streaming microphone input** — future enhancement (live audio → NiFi `ListenWebSocket` or chunked HTTP).
- **Multi-cluster demo** — one Minikube at a time.
- **Auth/TLS** — local demo only.

## Prerequisites

- `hf-token` Secret in `default` namespace (used by vLLM and the Whisper image build).
- `nifi-admin-creds` Secret in `cfm-streaming` namespace (admin/password for the NiFi REST API). Backend reads the password into `NIFI_PASSWORD` for dev; in-cluster the values come from a Secret-backed env var.
- CFM, CSM, CSA operators installed in their respective namespaces.
- `kubectl apply -f k8s/rbac.yaml` for the ServiceAccount + RBAC the Operators / Pods panels need. For Mac dev this is unnecessary — the backend falls back to `~/.kube/config`.
- Minikube running with GPU passthrough on the host.
- For host-side dev: `scripts/kafka-external-listener.sh` applied to the Strimzi Kafka CR.
