# CSO Level 2 — SSB CPU Tuning on Minikube

**Date:** 2026-06-24
**Cluster:** single-node minikube, 14 CPU, 98 days uptime (do **not** restart — CSO Operator Observability automation still in-progress)
**Namespace:** `cld-streaming`
**Repo for YAMLs:** `/Users/steven.matison/Documents/GitHub/ClouderaStreamingOperators/`

## Symptom

```
ssb-session-admin-taskmanager-16-1   0/1   Pending   17m
ssb-session-admin-taskmanager-16-2   0/1   Pending   17m
```

Scheduler event:

```
0/1 nodes are available: 1 Insufficient cpu.
no new claims to deallocate, preemption: 0/1 nodes are available:
1 No preemption victims found for incoming pod.
```

## Diagnosis

Node was at **94% CPU requested** (13.25 / 14 cores), but real usage from
`kubectl top node` was only **~720m (5%)**. Pure *requests* problem — every
Flink-flavored pod was requesting 2 CPU and actually using ~10m.

Top requesters vs actual:

| Pod | Request | Actual | Utilization |
|---|---|---|---|
| `ssb-sse` | 2000m | 9m | 0.45% |
| `ssb-session-admin` (JM) | 2000m | 9m | 0.45% |
| `ssb-session-admin-taskmanager-15-3` | 2000m | 11m | 0.55% |
| `ssb-session-admin-taskmanager-15-4` | 2000m | 17m | 0.85% |
| `ssb-session-admin-taskmanager-16-1` (pending) | 2000m | — | — |
| `ssb-session-admin-taskmanager-16-2` (pending) | 2000m | — | — |
| `ssb-postgresql` | 1000m | 17m | 1.7% |
| `flink-kubernetes-operator` | 1000m | 5m | 0.5% |

## Fix — drop requests, keep limits via `limit-factor`

Two patches, no minikube restart:

### 1. `ssb-sse` Deployment

```bash
kubectl patch deploy ssb-sse -n cld-streaming --type='json' -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"500m"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"1Gi"}
]'
```

Limits untouched (`cpu: 2`, `memory: 4Gi`).

### 2. `ssb-session-admin` FlinkDeployment

```bash
kubectl patch flinkdeployment ssb-session-admin -n cld-streaming --type=merge -p '{
  "spec": {
    "jobManager":  { "resource": { "cpu": 0.5, "memory": "2G", "ephemeralStorage": "4G" } },
    "taskManager": { "resource": { "cpu": 0.5, "memory": "2G", "ephemeralStorage": "4G" } },
    "flinkConfiguration": {
      "kubernetes.jobmanager.cpu.limit-factor": "4.0",
      "kubernetes.taskmanager.cpu.limit-factor": "4.0",
      "kubernetes.jobmanager.memory.limit-factor": "2.0",
      "kubernetes.taskmanager.memory.limit-factor": "2.0"
    }
  }
}'
```

Effective CPU **limit** stays at `0.5 × 4.0 = 2` — no behavioral cap change.
Effective memory limit stays at `2G × 2.0 = 4Gi`.

## Result

| | Before | After |
|---|---|---|
| Node CPU requested | **13.25 / 14 (94%)** | **7.25 / 14 (51%)** |
| Pending pods | 2 | 0 |
| Headroom recovered | — | **~6 CPU** |
| `ssb-5196` / `ssb-5209` session jobs | RUNNING | RUNNING ✅ |

The Flink operator bounced the JM, then reconciled. Old `15-x` / `16-x` TM
pods were replaced by fresh `1-1` and `1-2` under the new JM generation.
Both `FlinkSessionJob`s came back to `STABLE`.

## Key idea

> When real CPU usage is <5% of request and the scheduler can't fit new pods,
> **lower `requests.cpu` and raise `kubernetes.*.cpu.limit-factor`** to keep the
> same hard limit. The scheduler relaxes, the workload's worst-case cap is
> unchanged.

## Pattern to apply to the rest of `ClouderaStreamingOperators/`

Walk the other YAML/Services we have deployed and apply the same approach
when warranted. Likely candidates to inspect:

- `nifi-cluster-30-nifi2x*.yaml` — NiFi nodes often over-request CPU
- `nifi-combined.yaml`, `nifi-registry.yaml`
- `kafka-nodepool.yaml`, `kafka-eval*.yaml` — Strimzi `Kafka`/`KafkaNodePool` CRs (Strimzi has its own resource shape; edit `spec.kafka.resources` / `spec.zookeeper.resources` or the per-pool resources)
- `efm-deployment*.yaml`
- `embedding-server.yaml`
- `minifi-agent-pod.yaml`
- Anything else still pinning 1–2 CPU requests with <5% real usage

For each: `kubectl top pod` → compare to `requests.cpu` → if utilization is
trivial, drop `requests.cpu` and (for Flink) raise `limit-factor`, or (for
plain Deployments/StatefulSets) just lower the request while leaving the
limit alone.

## 2026-06-25 — Round 2 sweep (pre-EFM redeploy)

Patched four more Deployments in `cld-streaming`. Same pattern — drop
`requests.cpu`, leave `limits.cpu` alone:

```bash
kubectl patch deploy ssb-postgresql            -n cld-streaming --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"250m"}]'
kubectl patch deploy flink-kubernetes-operator -n cld-streaming --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"250m"},
  {"op":"replace","path":"/spec/template/spec/containers/1/resources/requests/cpu","value":"100m"}
]'
kubectl patch deploy ssb-mve                   -n cld-streaming --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"100m"}]'
kubectl patch deploy schema-registry           -n cld-streaming --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"100m"}]'
```

Net effect on `kubectl describe node`:

| | Before (post-round-1) | After |
|---|---|---|
| Node CPU requested | **7800m / 14 (55%)** | **4700m / 14 (33%)** |
| Headroom recovered | — | **~3 CPU** |

Pods rolled cleanly. `schema-registry` Flyway init-container did a one-shot
`repair` (a stale failed migration entry, unrelated to the resource change)
and then came up healthy — no further action.

## ⚠️ Memory is the next bottleneck, not CPU

After this round, the **scheduler** had plenty of room — but the **VM**
didn't. Deploying `efm-deployment-persisted.yaml` (Guaranteed QoS
`requests=limits=4Gi`) wedged the minikube docker container at
`827% CPU / 23.97 GiB / 24 GiB` and made the API server return
`TLS handshake timeout` for several minutes.

Why this is different from the CPU story:

- `kubectl describe node` showed **only ~64% memory _requests_** — that's
  the scheduling number. The kubelet was happy to schedule EFM.
- But the existing **memory _limits_** sum to **109% of node memory**
  (overcommitted, by design). Most pods sit well under their limits,
  which is the only reason the VM works at all.
- EFM is a JVM that genuinely _uses_ a few GB on startup. Adding it
  pushed real RSS past what the host VM has, the kernel started thrashing,
  and the control plane (etcd / apiserver / kubelet) was starved along
  with everything else.

So the level-2 trick — "raise limit-factor, lower request" — **does not
work for memory**. There's no `kubernetes.*.memory.limit-factor` analog
for plain Deployments, and even for Flink, raising the memory limit-factor
just makes the VM crash _harder_ when something actually allocates.

**The real fix is to bring memory _requests AND limits_ down on the JVM
pods that habitually run with <30% of their `-Xmx`.**

### Top memory-requesting pods to inspect

Run this to get the current snapshot:

```bash
kubectl get pods -A -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
rows=[]
for p in d["items"]:
    if p["status"].get("phase")!="Running": continue
    for c in p["spec"]["containers"]:
        m=c.get("resources",{}).get("requests",{}).get("memory","")
        if not m: continue
        # crude Gi normalization
        n=int(m[:-2]) if m.endswith("Gi") else int(m[:-2])//1024 if m.endswith("Mi") else 0
        if n>=1:
            rows.append((n,p["metadata"]["namespace"],p["metadata"]["name"],c["name"],m))
rows.sort(reverse=True)
for r in rows[:20]: print(f"{r[0]:>3}Gi  {r[1]:18} {r[2]:50} {r[3]:25} {r[4]}")'
```

Likely candidates on this cluster: `efm` (4Gi), `whisper-cpu-server`,
`vllm-cpu-server`, `embedding-server-cpu`, `ssb-session-admin-*`,
`nifi-*` (when running), and `prometheus-prometheus-*`. For each, compare
to `kubectl top pod` real usage:

- If `top` shows <30% of `requests.memory`: lower **both** request and
  limit. JVMs need `-Xmx` lowered too (e.g. add `JAVA_OPTS=-Xmx2g`) or
  they'll just allocate up to whatever heap was sized at startup.
- If `top` shows >70% of `requests.memory`: leave it. That pod is using
  what it asked for.

### Specifically for EFM

The committed YAML (`/Users/steven.matison/Documents/GitHub/ClouderaStreamingOperators/efm-deployment-persisted.yaml`)
ships with `requests: {cpu: 250m, memory: 4Gi}`, `limits: {cpu: 250m,
memory: 4Gi}`. After a normal boot, real EFM memory usage is ~1.2–1.8 Gi
on this workload. Recommended sizing once we have time to patch the YAML:

```yaml
resources:
  requests:
    cpu: "250m"
    memory: "1Gi"        # was 4Gi
  limits:
    cpu: "1"             # was 250m — let it burst on startup
    memory: "3Gi"        # was 4Gi
env:
  - name: JAVA_OPTS
    value: "-Xmx2g -Dspring.datasource.driver-class-name=org.postgresql.Driver -Def.db.driver.class.name=org.postgresql.Driver"
```

That moves EFM from Guaranteed QoS to Burstable, gives it CPU headroom for
the Spring boot window, and caps the JVM heap at 2G so it can't quietly
grow past the limit.

### How to recover when the VM does wedge

1. `docker stop minikube` (graceful — etcd flushes).
2. `minikube start` (DON'T `minikube delete` — preserves PVs and etcd).
3. Cluster comes back with everything still in place.

The 98-day uptime caveat (top of this doc) does NOT apply to a docker
stop/start of the minikube container — only to `minikube delete`.

## Caveats

- Editing a `FlinkDeployment` restarts the JM and bounces session jobs (brief outage; jobs restart from latest checkpoint / savepoint). Plan around active demos.
- Strimzi `Kafka` CR edits trigger rolling restarts of brokers — fine, but takes minutes.
- Don't lower **memory** requests below actual working set; OOMKills are worse than CPU throttling.
- This is a stopgap until the cluster is rebuilt under the in-progress CSO Operator Observability automation.

---

## 2026-06-29 — Windows Host Tuning (free RAM/CPU for Whisper + Docker/Minikube)

**Context:** Host RAM profile observed via `Get-Process`:
- `vmmemWSL` — 9.6 GB (WSL2 VM holding Docker + Minikube, expected)
- `Memory Compression` — 3.9 GB (Windows compressing RAM, sign of pressure)
- `MsMpEng` (Defender) — 208 MB
- `PhoneExperienceHost` (Phone Link) — 160 MB, unused

### MiNiFi Removal (completed)

MiNiFi C++ was still registered as a Windows service even after directory deletion.
Cleaned up in elevated PowerShell:

```powershell
# Removed stale Windows service
sc.exe delete "Apache NiFi MiNiFi"

# Removed leftover directories
Remove-Item -Path "C:\minifi" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "C:\WINDOWS\system32\nifi-minifi-cpp\" -Recurse -Force -ErrorAction SilentlyContinue

# Removed stale MSI registry entry (was still showing in Apps & features)
Remove-Item 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{7107577C-5716-45AE-90E6-07B3BABCD461}' -Recurse -Force
```

### Windows Services to Disable

Run these in an **elevated PowerShell** to stop and disable services that waste RAM/CPU on this workstation:

```powershell
$services = @(
    "SysMain",       # Superfetch — preloads apps into RAM, fights Whisper directly
    "DiagTrack",     # Microsoft telemetry (Connected User Experiences)
    "WSearch",       # Windows Search indexer — CPU/disk churn in background
    "Spooler",       # Print Spooler — no printer on this machine
    "dptftcs",       # Intel Dynamic Tuning Technology Telemetry
    "FvSvc",         # NVIDIA FrameView SDK — GPU benchmarking, not needed
    "DoSvc",         # Windows Update delivery optimization
    "WSAIFabricSvc", # Windows Subsystem for Android — not in use
    "SSDPSRV",       # UPnP/SSDP discovery — not needed
    "BthAvctpSvc",   # Bluetooth AVCTP
    "BTAGService",   # Bluetooth Audio Gateway
    "bthserv"        # Bluetooth Support Service
)

foreach ($svc in $services) {
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Set-Service  -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Write-Host "Disabled: $svc"
}
```

To re-enable any of these later:
```powershell
Set-Service -Name "WSearch" -StartupType Automatic
Start-Service "WSearch"
```

### Why SysMain matters most

`SysMain` (Superfetch) actively pre-fills RAM with predicted app data. When Whisper
loads a model into GPU/CPU memory, SysMain competes for the same RAM budget and
triggers the Memory Compression balloon. Disabling it frees several hundred MB
immediately and eliminates background page-file churn during inference.

### WSL2 Memory Note

`vmmemWSL` at 9.6 GB is the Hyper-V VM backing WSL2 — Docker and Minikube live
inside it. This is expected and should stay large. If Windows starts paging heavily,
a `.wslconfig` can cap it:

```ini
# C:\Users\<you>\.wslconfig
[wsl2]
memory=12GB      # hard cap on vmmemWSL
processors=10    # leave cores for Windows + Whisper
swap=4GB
```

Hold off on setting this until there's an actual OOM symptom — Docker/Minikube
benefit from the full allocation when running CSO workloads.
