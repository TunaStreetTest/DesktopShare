# CSO Operator App — Windows Test Plan

For driving from a Telegram `/bash` agent. Each step is a single shell line plus what to look for.

Assumes the agent's WSL/Linux home has:
- `~/DesktopShare`, `~/ClouderaStreamingOperators` already cloned
- `.env` exporting `CLOUDERA_USER`, `CLOUDERA_PASS`, `HF_TOKEN`, `NIFI_ADMIN_PASS`, `TOKEN`
- `kubectl`, `minikube`, `docker`, `git`, `python3`, `node`, `make`
- A Minikube up with GPU passthrough
- License at `/home/tunas/license.txt` (or wherever your agent puts it)

### Telegram `/bash` quirks (read before debugging)
- **No stdin** — avoid `kubectl run --rm -i ...`; the `-i` waits forever for input that the agent can't attach. Use `kubectl exec` against an existing pod instead.
- **No multi-line commands** — heredocs and any string with embedded newlines get mangled by the input box. Commit scripts to the repo and `kubectl exec ... python3 /app/scripts/...` instead of pasting Python inline.
- **`wget`/`curl` may be missing** in slim images — use `python3 -c '...'` (one line) or, better, a committed script.

## 0. Clone the new repo

```bash
/bash cd ~ && git clone https://github.com/cldr-steven-matison/cso-operator-app && ls cso-operator-app
```
**check:** sees `backend/`, `frontend/`, `flows/`, `k8s/`, `whisper/`, `scripts/`.

## 1. Operators + Cloudera streaming stack

```bash
/bash source ~/.env && nohup sh ~/DesktopShare/files/agent-install-operators.sh > deploy.log 2>&1 &
```
**check:** `kubectl get pods -n cld-streaming` shows Strimzi Kafka pods Running; `kubectl get pods -n cfm-streaming` shows `mynifi-0` and `cfm-operator-*`.

```bash
/bash cd ~/ClouderaStreamingOperators && kubectl apply -f kafka-eval.yaml -f kafka-nodepool.yaml -n cld-streaming && kubectl apply -f cluster-issuer.yaml && kubectl apply -f nifi-cluster-30-nifi2x-windows.yaml -n cfm-streaming && kubectl apply -f nifi-combined.yaml
```
**check:** Kafka pods reach Ready; NiFi pod reaches 7/7 Running.

## 2. Backing AI services (vLLM, Qdrant, embedding-server)

```bash
/bash cd ~/cso-operator-app && kubectl apply -f k8s/backing/vllm-Qwen2.5-3B-Instruct.yaml -f k8s/backing/qdrant-deployment.yaml -f k8s/backing/embedding-server.yaml
```
**check:** `kubectl get pods` (default ns) shows `vllm-server-*`, `qdrant-*`, `embedding-server-*` going through Pending → Running. vLLM needs to load the model — first start can take 5–10 min and you'll see `Application startup complete` in `kubectl logs deploy/vllm-server`.

`hf-token` Secret is required by vLLM. If missing:
```bash
/bash kubectl create secret generic hf-token --from-literal=HF_TOKEN="$HF_TOKEN"
```

## 3. Whisper image (GPU build)

```bash
/bash cd ~/cso-operator-app && eval $(minikube docker-env) && docker build -t streamwhisper:latest --build-arg HF_TOKEN="$HF_TOKEN" -f whisper/Dockerfile.whisper whisper/
```
**check:** ends with `naming to docker.io/library/streamwhisper:latest`. First build is ~6 min (CUDA + flash-attn + whisper-large-v3 prebake).

```bash
/bash cd ~/cso-operator-app && kubectl apply -f whisper/whisper-server.yaml
```
**check:** `kubectl get pod -l app=whisper-server` reaches Running 1/1. `kubectl logs deploy/whisper-server` shows uvicorn on :8001.

## 4. Kafka external listener (only needed if running the app outside the cluster)

If the app is deployed in-cluster (recommended on Windows), skip this — the in-cluster `KAFKA_BOOTSTRAP` works directly. If you want Mac-style host-side dev with port-forwards, run:
```bash
/bash cd ~/cso-operator-app && bash scripts/kafka-external-listener.sh
```
**check:** `kubectl get svc -n cld-streaming -l strimzi.io/component-type=kafka` shows 4 LB services (bootstrap + 3 brokers). Wait ~30s for the Strimzi rolling restart to finish.

## 5. NiFi flows: import the bundle

NiFi UI: open via `kubectl port-forward -n cfm-streaming svc/mynifi-web 8443:8443` and visit `https://localhost:8443/nifi/`.
- Username/password from `nifi-admin-creds` Secret in `cfm-streaming` (admin / `kubectl get secret nifi-admin-creds -n cfm-streaming -o jsonpath='{.data.password}' | base64 -d`).
- Drag a Process Group from the toolbar onto the canvas. Upload `~/cso-operator-app/flows/CSOOperatorApp.json`. The bundle includes all 3 flows under a parent group named `CSOOperatorApp`.
- `IngestDataToStream` exposes a single `ListenHTTP` on **port 9000** at path `/contentListener`. The flow's `RouteOnAttribute` branches docs (→ `new_documents`) vs audio (→ `new_audio`) based on `mime.type` / Content-Type. The backend posts every upload to `http://mynifi.cfm-streaming.svc.cluster.local:9000/contentListener` — no per-type endpoints anymore.
- Wire the InvokeHTTP processors that hit `vllm-service`, `embedding-server-service`, `qdrant`, and `whisper-service` to the in-cluster service DNS names if the imported config still has localhost overrides from a Mac dev session.

## 6. Build and deploy the app

```bash
/bash cd ~/cso-operator-app && eval $(minikube docker-env) && docker build -t cso-operator-app:latest .
```
**check:** ends with `naming to docker.io/library/cso-operator-app:latest`. ~2 min (Node bundle + Python deps).

```bash
/bash cd ~/cso-operator-app && kubectl apply -f k8s/configmap.yaml -f k8s/deployment.yaml -f k8s/service.yaml
```
**check:** `kubectl get pod -l app=cso-operator-app` is Running. The deployment also needs the NiFi password — if `/api/health` shows `nifi: false`, add it to the ConfigMap or as an env var:
```bash
/bash kubectl set env deploy/cso-operator-app NIFI_USERNAME=admin NIFI_PASSWORD="$(kubectl get secret nifi-admin-creds -n cfm-streaming -o jsonpath='{.data.password}' | base64 -d)"
```

## 7. Open the app

```bash
/bash minikube service cso-operator-app --url
```
**check:** prints something like `http://192.168.49.2:30080`. Open that in a browser.

## 8. Smoke test from inside the cluster

The repo ships `scripts/diagnose-query.py` baked into the runtime image — single-line probe of every hop the **Ask** button takes (env, vLLM `/v1/models`, vLLM chat completion, app `/api/health`, app `/api/query` SSE body).

```bash
/bash kubectl exec deploy/cso-operator-app -- python3 /app/scripts/diagnose-query.py
```
**check:**
- env block prints the resolved `VLLM_URL` / `VLLM_MODEL` / etc.
- `GET vllm /v1/models` → `200`, lists the model `VLLM_MODEL` is configured for.
- `POST vllm /v1/chat/completions` → `200` with a `choices[0].message.content` reply.
- `GET app /api/health` → all six services `ok: true`. The vllm entry now also returns `configured` + `loaded` so a model-name mismatch is visible.
- `POST app /api/query` → `event: sources` + a `data: {choices...delta.content}` chunk + `[DONE]`. Empty `sources` is fine on a fresh cluster — it just means Qdrant has 0 points yet.

For the NiFi state and Kafka topics endpoints, the same `python3 -c` pattern via `kubectl exec` works (Telegram `/bash` doesn't choke on a single line); the diagnostic script's `/api/health` already proves Kafka has topics.

## 9. End-to-end demo

In the browser:
1. **NiFi Controls** → click *Start* on each of the 3 cards. Badges turn `RUNNING` after the optimistic `STARTING…`.
2. **Ingest** → drop a `.wav` (or click *Use sample audio* to fetch the blog reference clip). Status line should read `delivery: kafka, topic: new_audio, offset: …`.
3. **Kafka Activity** → `new_audio` depth ticks up; a few seconds later `new_documents` ticks up too (Whisper transcribed it).
4. **All Topics** (bottom) → `new_audio` and `new_documents` highlighted, depths growing.
5. **RAG Query** → ask *How is rice prepared?* (sample audio) or *What is StreamToVLLM?* (sample doc). Streamed answer appears; expand sources to see the Qdrant chunks.

## 10. Failure modes worth checking

| Symptom | Cause | Fix |
|---|---|---|
| `/api/health` `nifi.ok=false` `error: 401` | NIFI_PASSWORD not set on the deploy | step 6 `kubectl set env` |
| `/api/health` `kafka.ok=false` `NodeNotReady` | App is using external bootstrap from a stale ConfigMap | Confirm `KAFKA_BOOTSTRAP=my-cluster-kafka-bootstrap.cld-streaming.svc:9092` (in-cluster) |
| `/api/health` `vllm.ok=false` `configured ... is not loaded` | `VLLM_MODEL` doesn't match what vLLM actually serves; `kubectl set env` from a previous session shadows the ConfigMap | Match `VLLM_MODEL` to the id reported by `GET /v1/models`. If a stale env override is shadowing the CM: `kubectl set env deploy/cso-operator-app VLLM_MODEL-` (trailing `-` removes), then `kubectl rollout restart deploy/cso-operator-app` |
| Ask button: blank answer, red error panel "vllm 404" | Same model-name mismatch as above | Same fix; re-run `scripts/diagnose-query.py` to confirm |
| Ask button: streamed answer with no sources / generic answer | Qdrant has 0 points | Drop a doc through Ingest, give `StreamTovLLM` a few seconds to upsert, re-ask |
| Ingest panel: CORS error on "Use sample audio" | (Pre-fix) Browser fetched `voiptroubleshooter.com` directly | Fixed — sample now goes through `/api/sample-audio` proxy |
| Whisper pod CrashLoopBackOff | image pulled before built, or no GPU | `kubectl describe pod -l app=whisper-server`; rebuild with `eval $(minikube docker-env)` |
| Recreate-collection 503 from app | Qdrant not yet up | `kubectl get pod -l app=qdrant`; wait |
| 403 on NiFi start/stop | Stale token + cookie jar (resolved in code, but if seen) | Restart the app pod |
| Frontend 404 on `/api/nifi/<name>/start` | Flow not imported, or name mismatch | Re-import `flows/CSOOperatorApp.json`; check `/api/nifi/state` |

## 11. Tear-down (optional, full reset)

```bash
/bash cd ~/cso-operator-app && kubectl delete -f k8s/service.yaml -f k8s/deployment.yaml -f k8s/configmap.yaml --ignore-not-found
/bash cd ~/cso-operator-app && kubectl delete -f whisper/whisper-server.yaml -f k8s/backing/embedding-server.yaml -f k8s/backing/qdrant-deployment.yaml -f k8s/backing/vllm-Qwen2.5-3B-Instruct.yaml --ignore-not-found
/bash sh ~/DesktopShare/files/agent-helm-uninstall.sh
```

## Reference

- App repo: <https://github.com/cldr-steven-matison/cso-operator-app>
- Plan: [`cso-operator-app-plan.md`](cso-operator-app-plan.md)
- Backing YAMLs: <https://github.com/cldr-steven-matison/ClouderaStreamingOperators>
- Source posts: [RAG with CSO](https://cldr-steven-matison.github.io/blog/RAG-with-Cloudera-Streaming-Operators/) · [Audio Transcription with CSO](https://cldr-steven-matison.github.io/blog/Audio-Transcription-with-Cloudera-Streaming-Operators/)
