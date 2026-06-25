# EFM Persistence + Agent Re-Registration Plan

## Context and Goal

EFM (Edge Flow Manager) is currently running with its default **H2 in-memory database**. Every pod restart wipes all agent classes, flow definitions, and resource registrations. This plan fixes that permanently by switching EFM to **PostgreSQL persistence** (`ssb-postgresql` already runs in the cluster), then re-registers all three agents so their classes and resources survive pod restarts indefinitely.

**End state:** EFM running with PostgreSQL, all 3 agent classes present in the UI (`WindowsDesktop`, `linux` K8s pod, `NvidiaNano` Jetson), agent flows pushable and surviving restarts.

---

## How We Work

### Environments in Play

| Layer | What It Is |
|---|---|
| Windows desktop host | Where MiNiFi Windows Desktop agent runs as a Windows service (`Apache NiFi MiNiFi`) |
| WSL2 Ubuntu (`tunas@MINI-Gaming-G1`) | Minikube host — all `kubectl`, `git`, `docker` commands run here |
| Minikube cluster (Docker driver) | Kubernetes cluster hosting EFM, Kafka, NiFi, vLLM, agents |
| Nvidia Jetson Nano | ARM64 edge device — MiNiFi C++ agent connecting back to EFM over LAN |

### Namespaces

| Namespace | What Lives There |
|---|---|
| `cld-streaming` | Kafka, EFM, `ssb-postgresql`, MiNiFi K8s agent pod, Strimzi operator |
| `cfm-streaming` | NiFi (`mynifi-0`), CFM operator |
| `default` | vLLM, Qdrant, embedding-server, whisper, cso-operator-app |

### Repos

| Repo | Local Path | Remote | Purpose |
|---|---|---|---|
| DesktopShare | `~/DesktopShare` | github.com/cldr-steven-matison/DesktopShare | All plans and documentation (this file) |
| ClouderaStreamingOperators | `~/ClouderaStreamingOperators` | github.com/cldr-steven-matison/ClouderaStreamingOperators | All K8s YAMLs — EFM, Kafka, NiFi, MiNiFi agents |
| cso-operator-app | `~/cso-operator-app` | github.com/cldr-steven-matison/cso-operator-app | The RAG operator web app |

### AI and Agentic Tools

- **Claude Code (claude.ai/code or VS Code extension)** — primary planning and documentation AI. Use it to write commands, debug failures, and update docs. All plans in `DesktopShare` are kept as the golden source of truth.
- **Telegram `/bash` agent** — remote shell into WSL2. Used to run `kubectl`, `docker`, `git` commands from phone or another machine. Key quirks:
  - No stdin — avoid `kubectl run --rm -i`; use `kubectl exec` against existing pods
  - No multi-line heredocs — commit scripts to the repo and run them via `kubectl exec ... /app/scripts/...`
  - Each `/bash` is a fresh shell — re-export env vars or `source ~/.env` at the start of each command
- **EFM UI** — accessed via `minikube service` tunnel: `http://127.0.0.1:<tunnel-port>/efm/ui/` (port changes each session — always use `minikube service efm -n cld-streaming` to get current URL)

### Key Files

| File | What It Contains |
|---|---|
| `~/DesktopShare/efm-binaries.md` | Full binary staging + Windows agent install + Python fix |
| `~/DesktopShare/efm-persistance.md` | EFM PostgreSQL setup + persisted deployment YAML |
| `~/ClouderaStreamingOperators/efm-configMap.yaml` | EFM properties ConfigMap (PostgreSQL connection inline) |
| `~/ClouderaStreamingOperators/efm-pvc.yaml` | PVC for agent binaries (`efm-agent-binaries`, 2Gi) |
| `~/ClouderaStreamingOperators/efm-deployment-persisted.yaml` | EFM deployment with PVC + ConfigMap mounts + PostgreSQL env vars |
| `~/efm-binaries/` | Local staging tree for all 4 binary types (cpp/linux, cpp/linuxaarch64, cpp/windows, java/linux) |

---

## Phase 0 — Cluster Up Check

Before touching EFM, confirm the cluster and dependencies are running.

```bash
# Pull latest docs and YAMLs
cd ~/DesktopShare && git pull
cd ~/ClouderaStreamingOperators && git pull

# Check cluster health
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed
```

**Must be Running before proceeding:**
- `ssb-postgresql-*` in `cld-streaming` — EFM's persistence backend
- Strimzi Kafka pods in `cld-streaming` — agents need Kafka for flow data
- `mynifi-0` in `cfm-streaming` — needed for flow testing later

If the cluster is cold, bring it up first:

```bash
source ~/.env && nohup sh ~/DesktopShare/files/agent-install-operators.sh > deploy.log 2>&1 &
```

Then apply Kafka + NiFi:

```bash
source ~/.env && cd ~/ClouderaStreamingOperators && \
  kubectl apply --filename kafka-eval.yaml,kafka-nodepool.yaml --namespace cld-streaming && \
  kubectl apply -f cluster-issuer.yaml && \
  kubectl apply -f nifi-cluster-30-nifi2x-windows.yaml -n cfm-streaming && \
  kubectl apply -f nifi-combined.yaml
```

Wait for Kafka and NiFi to be ready before moving to Phase 1.

---

## Phase 1 — Delete the Old (Non-Persisted) EFM

Tear down whatever EFM is running to start clean.

```bash
# Delete existing EFM deployment (leaves the PVC intact if it exists)
kubectl delete deployment efm -n cld-streaming --ignore-not-found
kubectl delete service efm -n cld-streaming --ignore-not-found
kubectl delete configmap efm-config -n cld-streaming --ignore-not-found
```

---

## Phase 2 — PostgreSQL One-Time Setup

This only needs to be done **once per cluster**. If `ssb-postgresql` already has an `efm` database from a prior session, skip to Phase 3 and verify with the check command at the end.

### 2a — Find the PostgreSQL pod

```bash
kubectl get pods -n cld-streaming | grep postgres
```

Copy the full pod name (e.g. `ssb-postgresql-0`).

### 2b — Create the EFM database and user

Run each line separately (Telegram `/bash` limitation — no heredocs):

```bash
PG=$(kubectl get pod -n cld-streaming -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
kubectl exec $PG -n cld-streaming -- psql -U postgres -c "CREATE DATABASE efm;"
kubectl exec $PG -n cld-streaming -- psql -U postgres -c "CREATE USER efm WITH PASSWORD 'efm_password';"
kubectl exec $PG -n cld-streaming -- psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE efm TO efm;"
kubectl exec $PG -n cld-streaming -- psql -U postgres -c "ALTER DATABASE efm OWNER TO efm;"
```

**Verify:**

```bash
kubectl exec $PG -n cld-streaming -- psql -U postgres -c "\l" | grep efm
```

Expected: a row showing `efm` database owned by `efm`.

### 2c — Create Kubernetes Secrets

```bash
# Database password (matches efm.db.password in ConfigMap and EFM_DB_PASSWORD in deployment)
kubectl create secret generic efm-db-pass \
  --from-literal=password=efm_password \
  --namespace cld-streaming

# Encryption password (required by efm-deployment-persisted.yaml)
kubectl create secret generic efm-encryption \
  --from-literal=encryption.password=efm_encryption_key \
  --namespace cld-streaming
```

> If these secrets already exist from a prior session, you'll get an `already exists` error — that's fine, skip them.

### 2d — Verify the Cloudera registry pull secret exists

```bash
kubectl get secret cloudera-registry -n cld-streaming
```

If missing, re-create it (requires your Cloudera credentials):

```bash
source ~/.env
kubectl create secret docker-registry cloudera-registry \
  --docker-server=container.repo.cloudera.com \
  --docker-username=$CLOUDERA_USER \
  --docker-password=$CLOUDERA_PASS \
  --namespace=cld-streaming
```

---

## Phase 3 — Deploy EFM with Persistence

### 3a — Pull the EFM image into Minikube

```bash
eval $(minikube docker-env)
docker login container.repo.cloudera.com
docker pull container.repo.cloudera.com/cloudera/efm:2.3.1.0-2
```

### 3b — Apply the persisted YAMLs

All three files live in `~/ClouderaStreamingOperators/`:

```bash
cd ~/ClouderaStreamingOperators
kubectl apply -f efm-configMap.yaml -n cld-streaming
kubectl apply -f efm-pvc.yaml -n cld-streaming
kubectl apply -f efm-deployment-persisted.yaml -n cld-streaming
```

### 3c — Wait for EFM to be ready

```bash
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=180s
```

### 3d — Verify EFM is using PostgreSQL (not H2)

```bash
EFM_POD=$(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}')
kubectl exec $EFM_POD -n cld-streaming -- sh -c 'find /opt/efm -name efm.properties -exec grep -E "db\.url|db\.driverClass" {} +'
```

**Expected output:**
```
efm.db.url=jdbc:postgresql://ssb-postgresql.cld-streaming.svc:5432/efm
efm.db.driverClass=org.postgresql.Driver
```

If you see `h2` anywhere instead, the ConfigMap mount is wrong — check `efm-configMap.yaml` and re-apply.

---

## Phase 4 — Stage Agent Binaries into EFM

EFM serves the install scripts and binaries to agents via its agent-deployer. The PVC survives pod restarts, so binaries only need to be staged once (unless the PVC was deleted).

### 4a — Check if binaries are already in the PVC

```bash
EFM_POD=$(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}')
kubectl exec -i $EFM_POD -n cld-streaming -- find /opt/efm/efm-2.3.1.0-2/agent-deployer/binaries -type f | sort
```

**Expected tree (all 4 must be present):**
```
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp/linux/1.26.02/minifi.tar.gz
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp/linuxaarch64/1.26.02/minifi.tar.gz
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp/windows/1.26.02/minifi.msi
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/java/linux/2.24.08.0-19/minifi.tar.gz
```

If all 4 are present, skip to Phase 5. If the PVC was reset or binaries are missing, stage them:

### 4b — Build local staging tree (if needed)

See `~/DesktopShare/efm-binaries.md` Steps 1–2 for the full build. Summary:

```bash
# Assumes ~/efm-binaries/ has the downloaded archives from Cloudera
rm -rf ~/efm-binaries/staging/
mkdir -p ~/efm-binaries/staging/binaries/cpp/linux/1.26.02
mkdir -p ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02
mkdir -p ~/efm-binaries/staging/binaries/cpp/windows/1.26.02
mkdir -p ~/efm-binaries/staging/binaries/java/linux/2.24.08.0-19

# Linux x86_64 — unpack, inject extensions, repack
tar -xf ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-bin-linux.tar.gz -C ~/efm-binaries/staging/binaries/cpp/linux/1.26.02/
mkdir -p /tmp/efm-ext-linux
tar -xf ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-extensions-linux.tar.gz -C /tmp/efm-ext-linux
find /tmp/efm-ext-linux -name "*.so" -exec cp {} ~/efm-binaries/staging/binaries/cpp/linux/1.26.02/nifi-minifi-cpp-1.26.02/extensions/ \;
unzip -o ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-python-components.zip -d ~/efm-binaries/staging/binaries/cpp/linux/1.26.02/nifi-minifi-cpp-1.26.02/
cd ~/efm-binaries/staging/binaries/cpp/linux/1.26.02/ && tar -czf minifi.tar.gz nifi-minifi-cpp-1.26.02/ && rm -rf nifi-minifi-cpp-1.26.02/ /tmp/efm-ext-linux

# Linux ARM64 — same pattern
tar -xf ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-bin-linux-arm64.tar.gz -C ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02/
mkdir -p /tmp/efm-ext-arm64
tar -xf ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-extensions-linux-arm64.tar.gz -C /tmp/efm-ext-arm64
find /tmp/efm-ext-arm64 -name "*.so" -exec cp {} ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02/nifi-minifi-cpp-1.26.02/extensions/ \;
unzip -o ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-python-components.zip -d ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02/nifi-minifi-cpp-1.26.02/
cd ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02/ && tar -czf minifi.tar.gz nifi-minifi-cpp-1.26.02/ && rm -rf nifi-minifi-cpp-1.26.02/ /tmp/efm-ext-arm64

# Windows MSI — direct copy
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-x64.msi ~/efm-binaries/staging/binaries/cpp/windows/1.26.02/minifi.msi

# Java Linux — direct copy
cp ~/efm-binaries/minifi-2.24.08.0-19-bin.tar.gz ~/efm-binaries/staging/binaries/java/linux/2.24.08.0-19/minifi.tar.gz
```

### 4c — Stream binaries into EFM pod (tar pipe — works with Telegram /bash)

```bash
EFM_POD=$(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}')
cd ~/efm-binaries/staging/ && tar -cf - binaries/ | kubectl exec -i $EFM_POD -n cld-streaming -- tar -xf - -C /opt/efm/efm-2.3.1.0-2/agent-deployer/
```

### 4d — Restart EFM so it indexes the new binaries

```bash
kubectl rollout restart deployment/efm -n cld-streaming
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
```

### 4e — Verify EFM UI shows all 3 binary types

Open EFM UI (get URL with `minikube service efm -n cld-streaming`) → **Agent Deployer** → confirm dropdown shows:
- `v1.26.02 - linux`
- `v1.26.02 - linuxaarch64`
- `v1.26.02 - windows`
- `v2.24.08.0-19 - linux` (Java)

---

## Phase 5 — Expose EFM for Agent Connections

Agents need to reach EFM. Port-forward exposes it on the WSL2 host:

```bash
# Keep this running in a terminal (or use nohup for Telegram /bash)
kubectl port-forward --address 0.0.0.0 service/efm 10090:10090 -n cld-streaming &
```

Get the WSL2 host's LAN IP (so Windows desktop and Jetson can reach it):

```bash
ip addr show eth0 | grep "inet " | awk '{print $2}' | cut -d/ -f1
```

**EFM URLs:**
- From WSL2: `http://localhost:10090/efm/ui/`
- From Windows host: `http://<WSL2-LAN-IP>:10090/efm/ui/`
- From Jetson: `http://<WSL2-LAN-IP>:10090/efm/ui/`

Windows Firewall must allow port 10090 inbound. If not already set:

```powershell
# Run as Administrator on Windows
New-NetFirewallRule -DisplayName "Allow EFM Port 10090" -Direction Inbound -Protocol TCP -LocalPort 10090 -Action Allow
```

---

## Phase 6 — Re-Register Agent 1: Linux K8s Pod

This is the MiNiFi C++ agent running as a pod inside the cluster.

### 6a — Get the EFM install script and apply

From EFM UI → Agent Deployer → select `cpp / linux / 1.26.02` → copy the curl command. Or use the saved command:

```bash
curl -L \
 -d agentClass=linux \
 -d agentIdentifier=$(cat /proc/sys/kernel/random/uuid) \
 -d agentType=cpp \
 -d agentVersion=1.26.02 \
 -d autoConfigureSecurity=false \
 -d baseUrl=http%3A%2F%2F127.0.0.1%3A10090%2Fefm%2Fapi \
 -d hbPeriod=5000 \
 -d osArch=linux \
 -d serviceName=minifi \
 -d serviceUser=minifi \
 -d trustSelfSignedCertificates=false \
 http://127.0.0.1:10090/efm/api/agent-deployer/script | bash -
```

> If running inside a K8s pod (minifi-agent-k8s), replace `127.0.0.1:10090` with the EFM service DNS: `efm.cld-streaming.svc.cluster.local:10090`

### 6b — Apply the agent pod YAML

```bash
kubectl delete pod minifi-agent-k8s -n cld-streaming --ignore-not-found
kubectl apply -f ~/ClouderaStreamingOperators/minifi-agent-pod.yaml
kubectl logs minifi-agent-k8s -n cld-streaming -f
```

### 6c — Verify in EFM UI

Agent class `linux` appears in the dashboard within one heartbeat (~5s). Click it — agent should show as **Connected**.

---

## Phase 7 — Re-Register Agent 2: Windows Desktop

The Windows native MiNiFi service is already installed with Python support (from the ADDLOCAL=ALL fix). It just needs to reconnect to the new EFM URL.

### 7a — Update the EFM URL in MiNiFi config (on Windows, as Administrator)

The agent's `bootstrap.conf` points to the old EFM URL. Update it to the new port-forwarded address:

```powershell
# Find and update bootstrap.conf
Get-Content "C:\WINDOWS\system32\nifi-minifi-cpp\conf\bootstrap.conf" | Select-String "efm"
# Update nifi.efm.url to http://<WSL2-LAN-IP>:10090/efm/api
(Get-Content "C:\WINDOWS\system32\nifi-minifi-cpp\conf\bootstrap.conf") -replace 'nifi.efm.url=.*', 'nifi.efm.url=http://<WSL2-LAN-IP>:10090/efm/api' | Set-Content "C:\WINDOWS\system32\nifi-minifi-cpp\conf\bootstrap.conf"
```

### 7b — Restart the Windows service

```powershell
Restart-Service "Apache NiFi MiNiFi"
Get-Service "Apache NiFi MiNiFi"
```

### 7c — Verify extensions still present

```powershell
ls C:\WINDOWS\system32\nifi-minifi-cpp\extensions\minifi-python-script-extension.dll
ls C:\WINDOWS\system32\nifi-minifi-cpp\extensions\minifi_native.pyd
```

### 7d — Verify in EFM UI

Agent class `WindowsDesktop` appears in dashboard within one heartbeat. If the class name changed from the prior session, check `bootstrap.conf` for `nifi.efm.agent.class`.

---

## Phase 8 — Re-Register Agent 3: Nvidia Jetson Nano (ARM64)

The Jetson runs MiNiFi C++ for ARM64. It needs to reach EFM over the LAN.

### 8a — SSH into Jetson and run EFM deployer

```bash
# On Jetson (SSH from WSL2 or Windows terminal)
curl -L \
 -d agentClass=NvidiaNano \
 -d agentIdentifier=$(cat /proc/sys/kernel/random/uuid) \
 -d agentType=cpp \
 -d agentVersion=1.26.02 \
 -d autoConfigureSecurity=false \
 -d baseUrl=http%3A%2F%2F<WSL2-LAN-IP>%3A10090%2Fefm%2Fapi \
 -d hbPeriod=5000 \
 -d osArch=linuxaarch64 \
 -d serviceName=minifi \
 -d serviceUser=minifi \
 -d trustSelfSignedCertificates=false \
 http://<WSL2-LAN-IP>:10090/efm/api/agent-deployer/script | bash -
```

### 8b — Verify agent is running on Jetson

```bash
# On Jetson
systemctl status minifi
tail -f /opt/nifi-minifi-cpp-1.26.02/logs/minifi-app.log
```

### 8c — Verify in EFM UI

Agent class `NvidiaNano` appears in dashboard. Agent shows **Connected**.

---

## Phase 9 — Final Verification

### EFM Dashboard must show:

| Agent Class | Type | Status |
|---|---|---|
| `linux` | cpp / linux | Connected |
| `WindowsDesktop` | cpp / windows | Connected |
| `NvidiaNano` | cpp / linuxaarch64 | Connected |

### Confirm PostgreSQL is persisting data

Bounce EFM deliberately and confirm classes survive:

```bash
kubectl rollout restart deployment/efm -n cld-streaming
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
```

Refresh EFM UI — all 3 agent classes must still appear. If they do, persistence is working.

### Confirm resources survived

EFM UI → **Resources** — any flow definitions, processor configs, or assets pushed before the restart should still be present.

---

## Failure Modes

| Symptom | Cause | Fix |
|---|---|---|
| EFM pod crashes on startup | `efm-encryption` secret missing or `efm-db-pass` secret missing | Create both secrets (Phase 2c) |
| EFM logs `Connection refused` to PostgreSQL | `ssb-postgresql` not running or DB not created | Phase 0 cluster check + Phase 2 |
| EFM starts but UI shows H2 | ConfigMap not mounted or wrong properties path | Verify `efm-deployment-persisted.yaml` volumeMount path matches `find /opt/efm -name efm.properties` |
| Agent deployer shows no binary types | Binaries not in PVC or PVC was deleted | Phase 4 re-stage |
| `400 BAD_REQUEST` from EFM on binary upload | More than 1 archive file in a leaf directory | Each `binaries/` leaf dir must have exactly 1 file |
| Agent class missing after EFM restart | EFM was using H2 (not PostgreSQL) — persistence not applied | Verify Phase 3d output shows `jdbc:postgresql://` |
| Windows agent class missing | `bootstrap.conf` still points to old EFM URL/port | Phase 7a — update `nifi.efm.url` |
| Jetson agent can't reach EFM | Windows Firewall blocking port 10090 or port-forward dropped | Phase 5 firewall rule + restart port-forward |

---

## Reference

- Docs: `~/DesktopShare/efm-binaries.md` — binary staging + Windows Python fix  
- Docs: `~/DesktopShare/efm-persistance.md` — PostgreSQL setup + deployment YAMLs  
- YAMLs: `~/ClouderaStreamingOperators/efm-configMap.yaml`, `efm-pvc.yaml`, `efm-deployment-persisted.yaml`  
- EFM version: `2.3.1.0-2`  
- MiNiFi C++ version: `1.26.02`  
- MiNiFi Java version: `2.24.08.0-19`  
- PostgreSQL: `ssb-postgresql.cld-streaming.svc:5432`, database `efm`, user `efm`
