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

## Caveats

- Editing a `FlinkDeployment` restarts the JM and bounces session jobs (brief outage; jobs restart from latest checkpoint / savepoint). Plan around active demos.
- Strimzi `Kafka` CR edits trigger rolling restarts of brokers — fine, but takes minutes.
- Don't lower **memory** requests below actual working set; OOMKills are worse than CPU throttling.
- This is a stopgap until the cluster is rebuilt under the in-progress CSO Operator Observability automation.
