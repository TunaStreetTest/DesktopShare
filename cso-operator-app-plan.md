# CSO Operator App — Plan

A single demo app that exercises every concept from the **RAG with Cloudera Streaming Operators** and **Insanely Fast Audio Transcription with Cloudera Streaming Operators** posts: ingest documents, ingest audio, watch Kafka move it, search Qdrant, ask vLLM, and drive NiFi flows from one screen.

Supersedes `rag-app-plan.md` (RAG-only scope). Local demo only — no auth, no production hardening.

## Source posts (canonical)

- **RAG with Cloudera Streaming Operators** — `cldr-steven-matison.github.io/_posts/2026-03-22-RAG with Cloudera Streaming Operators.md`
  - vLLM (Qwen2.5-3B-Instruct), Qdrant (`my-rag-collection`, 768-d Cosine), TEI embedding (nomic-embed-text-v1), NiFi flows `IngestToStream` + `StreamTovLLM`, Kafka topic `new_documents`.
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
Args:
```
Qwen/Qwen2.5-3B-Instruct
--quantization bitsandbytes
--load-format bitsandbytes
--gpu-memory-utilization 0.75
--max-model-len 32000
--enable-chunked-prefill
--enforce-eager
--enable-auto-tool-choice
--tool-call-parser qwen3_coder
```
Env: `HF_TOKEN` from `Secret/hf-token` key `HF_TOKEN`. GPU limit 1. `/dev/shm` emptyDir 2Gi.
Endpoint used by app: `POST /v1/chat/completions` (OpenAI-compatible, supports `stream: true`).

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
| `new_audio` | NiFi `IngestDataToStream` | NiFi `StreamToWhisper` | raw audio bytes |
| `new_documents` | NiFi `IngestToStream` *and* `StreamToWhisper` | NiFi `StreamTovLLM` | text |

Bootstrap: `my-cluster-kafka-bootstrap.cld-streaming.svc:9092`. App uses `aiokafka` for topic stats + tail.

There is no separate transcript topic — Whisper republishes into `new_documents` so the existing RAG flow handles transcripts unchanged.

### NiFi (CFM, namespace `cfm-streaming`)

UI (in-cluster): `https://mynifi-web.mynifi.cfm-streaming.svc.cluster.local/nifi/`
REST: same host. Process groups (each shipped as JSON in `flows/`):

| Flow | Role | Inputs | Outputs |
|---|---|---|---|
| `IngestToStream` | Doc ingest | `ListenHTTP` (added) **or** `GenerateFlowFile`+`InvokeHTTP` | `new_documents` |
| `IngestDataToStream` | Audio ingest | `ListenHTTP` (added) **or** `GenerateFlowFile`+`InvokeHTTP` | `new_audio` |
| `StreamToWhisper` | Transcribe | `ConsumeKafka_2_6 new_audio` | `InvokeHTTP whisper-service:8001/transcribe` → `EvaluateJsonPath $.text` → `ReplaceText` → `PublishKafka_2_6 new_documents` |
| `StreamTovLLM` | RAG indexer | `ConsumeKafka_2_6 new_documents` | `SplitText` (20-line) → `ExtractText` → `ReplaceText` (embed JSON) → `InvokeHTTP embed` → `EvaluateJsonPath` → `ReplaceText` (Qdrant upsert) → `InvokeHTTP qdrant upsert` |

A `ListenHTTP` processor is added at the head of `IngestToStream` and `IngestDataToStream` so the backend can `POST` files directly. The original `GenerateFlowFile`+`InvokeHTTP` pair stays in place to support a "demo without uploading" path that pulls from a sample URL.

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
| `POST /api/query` | Embed → Qdrant top-k → build prompt → vLLM (SSE; pass through native vLLM stream chunks) |
| `POST /api/ingest/doc` | Multipart upload → `POST` to `IngestToStream` ListenHTTP |
| `POST /api/ingest/audio` | Multipart upload → `POST` to `IngestDataToStream` ListenHTTP |
| `GET  /api/nifi/state` | State of the 4 process groups |
| `POST /api/nifi/{name}/start\|stop` | Toggle by name (resolved to UUID + revision at startup) |
| `GET  /api/qdrant/stats` | Point count, segments |
| `POST /api/qdrant/recreate` | Drop + recreate `my-rag-collection` (768-d Cosine) |
| `GET  /api/kafka/topics` | Depth/lag for `new_audio`, `new_documents` |
| `GET  /api/kafka/tail/{topic}` | SSE tail of recent messages |
| `GET  /api/health` | Pings every backing service |

**Stack**: FastAPI, `httpx.AsyncClient` (vLLM/Qdrant/embedding/NiFi/Whisper), `aiokafka` (topic stats + tail), Pydantic settings from ConfigMap/env.

**NiFi process-group resolution**: at startup, GET `/process-groups/root/process-groups` → cache `{name: (id, revision)}`. State changes use `PUT /flow/process-groups/{id}` with `{"id": "...", "state": "RUNNING|STOPPED"}` and the cached revision (refreshed on 409).

## Frontend panels

- **Demo Mode** — guided 4-step walkthrough:
  1. Start the four flows
  2. Drop a doc *or* audio file (or click "use sample" → blog test WAV `OSR_us_000_0010_8k.wav`)
  3. Watch the relevant Kafka topic light up
  4. Ask a pre-baked question (`What is StreamToVLLM?` for docs, `How is rice prepared?` for the sample audio) and stream the answer
- **Ingest** — dropzone with format detection (audio → IngestDataToStream, doc → IngestToStream).
- **NiFi Controls** — four cards: `IngestToStream`, `IngestDataToStream`, `StreamToWhisper`, `StreamTovLLM`. Start/stop, live state badge.
- **Kafka Activity** — live tail of `new_audio` (binary preview/length) and `new_documents` (text). Depth/lag indicators per topic.
- **RAG Query** — chat UI with vLLM streaming, expandable source chunks (Qdrant payloads), prompt history.
- **Health bar** — green/red dots per backing service, click for details.

State: React hooks. Streaming: `EventSource` for SSE. UI primitives: shadcn Button/Card/Toast/Dialog/Tabs.

## Repo layout (`cso-operator-app`)

```
cso-operator-app/
├── README.md
├── backend/
│   ├── main.py
│   ├── routers/  (query.py, ingest.py, nifi.py, qdrant.py, kafka.py, health.py)
│   ├── services/ (vllm.py, qdrant.py, embedding.py, whisper.py, nifi.py, kafka.py)
│   ├── config.py
│   ├── requirements.txt
│   └── Dockerfile
├── frontend/
│   ├── src/  (components/, pages/, api/, hooks/, types.ts)
│   ├── vite.config.ts, tailwind.config.ts, package.json
├── whisper/
│   ├── Dockerfile.whisper        # full Dockerfile from audio post
│   └── whisper-server.yaml
├── flows/                        # exported NiFi process groups w/ ListenHTTP added
│   ├── IngestToStream.json
│   ├── IngestDataToStream.json
│   ├── StreamToWhisper.json
│   └── StreamTovLLM.json
├── k8s/
│   ├── deployment.yaml           # the app itself
│   ├── service.yaml              # NodePort 30080
│   ├── configmap.yaml            # all backing service URLs/ports
│   └── backing/                  # copies from ClouderaStreamingOperators
│       ├── vllm-Qwen2.5-3B-Instruct.yaml
│       ├── qdrant-deployment.yaml
│       └── embedding-server.yaml
├── samples/
│   ├── OSR_us_000_0010_8k.wav    # blog reference audio
│   └── streamtovllm.md           # blog reference doc
├── scripts/
│   ├── mac-dev.sh                # port-forwards + uvicorn + vite
│   ├── deploy.sh                 # minikube image build + kubectl apply
│   └── bootstrap-stack.sh        # apply backing/, build whisper image, import flows
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
  QDRANT_URL: "http://qdrant.default.svc.cluster.local:6333"
  EMBED_URL: "http://embedding-server-service.default.svc.cluster.local:80"
  WHISPER_URL: "http://whisper-service.default.svc.cluster.local:8001"
  NIFI_URL: "https://mynifi-web.mynifi.cfm-streaming.svc.cluster.local"
  KAFKA_BOOTSTRAP: "my-cluster-kafka-bootstrap.cld-streaming.svc:9092"
  QDRANT_COLLECTION: "my-rag-collection"
  EMBED_DIM: "768"
  TOPIC_AUDIO: "new_audio"
  TOPIC_DOCS: "new_documents"
```

For Mac dev, `.env.local` overrides with `localhost` ports (8080 for embedding via port-forward, 8000/6333/8001 for the rest).

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

1. **Repo scaffold** + README + Makefile + ConfigMap.
2. **Backend skeleton** + `/api/health` (proves connectivity to all five services).
3. **Query path** end-to-end (embed → Qdrant → vLLM streaming) — most demoable, smallest surface.
4. **NiFi controls** — name→UUID resolution, start/stop, state.
5. **Qdrant management** — recreate, stats.
6. **Kafka activity** — topics endpoint, then SSE tail with `aiokafka`.
7. **Ingest** — add ListenHTTP to `IngestToStream` and `IngestDataToStream` flow JSON, then frontend dropzone.
8. **Frontend polish** — Demo Mode walkthrough, health bar, toasts, source-chunk reveal in chat.
9. **Containerize** + deploy on Mac Minikube.
10. **Test on Windows** Minikube — adjust ConfigMap if any service names differ; rebuild whisper image with `eval $(minikube docker-env)`.

## Out of scope

- **Streaming microphone input** — future enhancement (live audio → NiFi `ListenWebSocket` or chunked HTTP).
- **Multi-cluster demo** — one Minikube at a time.
- **Auth/TLS** — local demo only.

## Prerequisites

- `hf-token` Secret in `default` namespace (used by vLLM and the Whisper image build).
- CFM, CSM, CSA operators installed in their respective namespaces.
- Minikube running with GPU passthrough on the host.
