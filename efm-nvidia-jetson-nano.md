**Cloudera Edge Flow Manager (EFM) with Jetson Orin Nano for AI at the Edge**

Hey folks, Steven Matison here. If you’ve been following my Cloudera Community posts, my GitHub pages at [cldr-steven-matison.github.io](https://cldr-steven-matison.github.io/), or the fresh content now flowing to [stevenmatison.com](https://stevenmatison.com), you know I’m all about making complex streaming, flow management, and edge AI setups actually *work* on real hardware — windows, mac, ubuntu, docker, kubernetes, and now a new NVIDIA Jetson Orin Nano.  

Today we’re going deep: with local lab for **Cloudera Edge Flow Manager (EFM / CEM)**, next to the full **Cloudera Streaming Operator (CSO)** stack (CFM + CSM + CSA) on Minikube Kubernetes, and then deploying **MiNiFi C++ agents** to NVIDIA Jetson Orin Nano.  

The goal? Design ai enabled nifi flows + ML model assets once in EFM, push them to edge agents.  We will execute custom models *inside* MiNiFi on the Jetson, and ship system + processor + model metrics straight to the Prometheus instance living inside the CSO stack. All of it documented exactly the way I like — repeatable, with every command, and all the gotchas spelled out.

This post directly extends:
- My full **Cloudera Streaming Operators on Minikube** guide on the Cloudera Community (and the companion repo).
- My **Observability with Cloudera Streaming Operators** blog (Prometheus + Grafana for NiFi, Kafka, Flink).
- My **[MiNiFi Kubernetes Playfround](https://github.com/cldr-steven-matison/MiNiFi-Kubernetes-Playground)** for testing MiNiFi
- Official Cloudera CEM/EFM and MiNiFi C++ docs (with my WSL2/Windows/Jeston tweaks).

Let’s dive in.


### 1. Create the EFM Database & User in Your Existing SSB Postgres

First, find the Postgres pod:

```bash
kubectl get pods -n cld-streaming | grep postgres
```

Copy the pod name (e.g. `ssb-postgresql-abc123-xyz`).

Now run these one-time psql commands **inside** that pod:

```bash
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "CREATE DATABASE efm;"
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "CREATE USER efm WITH PASSWORD 'efm_password';"
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE efm TO efm;"
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "ALTER DATABASE efm OWNER TO efm;"
```

### 2. Create the EFM Database Password Secret

```bash
kubectl create secret generic efm-db-pass \
  --from-literal=password=efm_password \
  --namespace cld-streaming
```

### 3. (One-time) Pull the Official EFM Docker Image into Minikube

```bash
docker login container.repo.cloudera.com   # use your Cloudera creds
minikube ssh -- docker pull container.repo.cloudera.com/cloudera/efm:2.2.0.0-86
```

Use the exact tag that matches your CSO / CEM entitlement — 2.2.0.0-86 is the one I’m running in the lab right now. Check your Cloudera archive for the latest matching version.

### 4. EFM Deployment YAML (`efm-deployment.yaml`)

Create this file in your working directory:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: efm
  namespace: cld-streaming
  labels:
    app: efm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: efm
  template:
    metadata:
      labels:
        app: efm
    spec:
      imagePullSecrets:
      - name: cloudera-registry   # you already created this for CSO
      containers:
      - name: efm
        image: container.repo.cloudera.com/cloudera/efm:2.2.0.0-86
        ports:
        - containerPort: 10090   # EFM UI / API
        - containerPort: 9092    # Prometheus metrics
        env:
        - name: EFM_DB_URL
          value: "jdbc:postgresql://ssb-postgresql.cld-streaming.svc:5432/efm"
        - name: EFM_DB_USER
          value: efm
        - name: EFM_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: efm-db-pass
              key: password
        - name: EFM_ENCRYPTION_PASSWORD
          valueFrom:
            secretKeyRef:
              name: efm-encryption   # create this if you don't have it yet
              key: encryption.password
        resources:
          requests:
            cpu: "2"
            memory: "4Gi"
          limits:
            cpu: "4"
            memory: "8Gi"
```

**Create the encryption secret first** (if you haven’t already):

```bash
kubectl create secret generic efm-encryption \
  --from-literal=encryption.password=SuperSecretEFMKey123! \
  --namespace cld-streaming
```

Apply it:

```bash
kubectl apply -f efm-deployment.yaml
```

### 5. Expose EFM for Easy Access

```bash
kubectl expose deployment efm --type=NodePort --port=10090 -n cld-streaming
minikube service efm -n cld-streaming --url
```

Open that URL in your browser — you should land on the EFM login screen. First login creates the admin account.

### 6. Add EFM to Your CSO Prometheus Observability

Create `efm-servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: efm
  namespace: cld-streaming
spec:
  selector:
    matchLabels:
      app: efm
  endpoints:
  - port: metrics
    path: /efm/actuator/prometheus
    interval: 15s
```

```bash
kubectl apply -f efm-servicemonitor.yaml
```

EFM metrics now flow straight into the same Prometheus/Grafana stack you already have for NiFi, Flink, Kafka, and Schema Registry.

### Deploy MiNiFi C++ Agents from EFM (The Fun Part)

In EFM UI:
1. Design your flow (or import one).
2. Add **assets** (your TensorFlow/ONNX models, Python scripts, etc.).
3. Create a **Class** for each target environment (Windows C++, Docker, K8s, Jetson).
4. Generate the **one-line installer command** (new in recent EFM — game changer).

#### MiNiFi Target: NVIDIA Jetson Orin Nano (Edge AI)
Jetson runs Ubuntu 22.04 + JetPack. Install MiNiFi C++ via the Linux tarball (x86_64 works via Docker or native if you cross-compile for aarch64 — Cloudera provides Linux binaries; for pure ARM I recommend the Docker route with NVIDIA runtime).

On Jetson:
```bash
# Install NVIDIA Container Toolkit (already in JetPack)
docker run --rm --runtime=nvidia --gpus all \
  -v /path/to/flow.yml:/opt/minifi/config/flow.yml \
  -v /path/to/models:/opt/minifi/models \
  your-minifi-cpp-jetson-image
```

**Model execution inside MiNiFi**:
- Use `ExecutePython` + ONNX/TensorRT Python bindings, or the built-in `TensorFlow` / `ExecuteML` processors (C++ extensions).
- Bundle models as EFM **assets** → they land in the agent’s asset directory automatically.
- Processor config points to `/opt/minifi/models/my-model.onnx`.

**Metrics to Prometheus**:
MiNiFi C++ has native Prometheus support. In `minifi.properties`:
```properties
# Enable Prometheus
nifi.c2.enable.metrics=true
nifi.c2.metrics.publisher=prometheus
nifi.c2.metrics.publisher.prometheus.port=9092
```
The agent registers itself with EFM, EFM knows the Prometheus scrape target, or you add a static scrape in your CSO Prometheus config. My Grafana dashboard will now show Jetson CPU/GPU/temp + model inference latency + flow throughput.

### 6. End-to-End Validation

1. Push a flow from EFM → all agents receive it within seconds.
2. Trigger data on the Jetson (camera feed, sensor, etc.).
3. Watch models execute locally on the Orin Nano GPU.
4. Metrics appear in Grafana (EFM + CSO + MiNiFi all in one place).
5. Scale: add more Jetson devices, Windows edge nodes, or K8s pods — EFM handles it.

