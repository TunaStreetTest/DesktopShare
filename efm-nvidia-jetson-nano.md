**Setting Up Cloudera Edge Flow Manager (EFM) on Windows + WSL2 Ubuntu, Full Cloudera Streaming Operators (CSO) on Minikube, and MiNiFi C++ Agent Deployments to Windows, Docker, K8s, and Jetson Orin Nano for Edge AI Flows & Prometheus Metrics**

Hey folks, Steven Matison here. If you’ve been following my Cloudera Community posts, my GitHub pages at [cldr-steven-matison.github.io](https://cldr-steven-matison.github.io/), or the fresh content now flowing to [stevenmatison.com](https://stevenmatison.com), you know I’m all about making complex streaming, flow management, and edge AI setups actually *work* on real hardware — including my own Windows dev box with WSL2.  

Today we’re going deep: a complete, production-like local lab for **Cloudera Edge Flow Manager (EFM / CEM)** running in WSL2 Ubuntu, the full **Cloudera Streaming Operator (CSO)** stack (CFM + CSM + CSA) on Minikube Kubernetes, and then deploying **MiNiFi C++ agents** everywhere — native Windows (C++), Docker, Kubernetes pods, *and* NVIDIA Jetson Orin Nano.  

The goal? Design flows + ML model assets once in EFM, push them to edge agents, execute TensorFlow / ONNX / custom models *inside* MiNiFi on the Jetson, and ship system + processor + model metrics straight to the Prometheus instance living inside your CSO stack. All of it documented exactly the way I like — repeatable, with every command, YAML, and gotcha spelled out.

This post directly extends:
- My full **Cloudera Streaming Operators on Minikube** guide on the Cloudera Community (and the companion repo).
- My **Observability with Cloudera Streaming Operators** blog (Prometheus + Grafana for NiFi, Kafka, Flink).
- Official Cloudera CEM/EFM and MiNiFi C++ docs (with my WSL2/Windows/Jeston tweaks).

Let’s dive in.

### 1. Prerequisites & Environment (Windows 11 + WSL2 Ubuntu)

You already have WSL2 Ubuntu installed — perfect. I run everything inside WSL2 for consistency (Minikube works beautifully there).

```bash
# In PowerShell (Windows)
wsl --update
wsl -d Ubuntu

# Inside WSL2 Ubuntu
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl wget git unzip build-essential openjdk-17-jdk postgresql docker.io docker-compose-v2
```

- **Minikube**: Install via official script (WSL2 driver).
- **Helm**, **kubectl**, **k9s** (for convenience).
- **Cloudera license** (evaluation or enterprise) and container-registry credentials.
- **NVIDIA Jetson Orin Nano** pre-flashed with JetPack 6.x (Docker + NVIDIA Container Toolkit already there).

Clone my CSO repo now (we’ll use it heavily):
```bash
git clone https://github.com/cldr-steven-matison/ClouderaStreamingOperators.git
cd ClouderaStreamingOperators
```

### 2. Install Cloudera Edge Flow Manager (EFM) Standalone in WSL2 Ubuntu

EFM is Java-based and runs cleanly on Ubuntu 22.04/24.04 inside WSL2. Follow the official standalone path (no Cloudera Manager needed for a lab).

**Step-by-step (adapted for WSL2):**

1. **Database** (PostgreSQL — EFM’s recommended):
   ```bash
   sudo -u postgres psql -c "CREATE DATABASE efm;"
   sudo -u postgres psql -c "CREATE USER efm WITH PASSWORD 'efm_password';"
   sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE efm TO efm;"
   ```

2. **Java 17** (already installed above). Set `JAVA_HOME`:
   ```bash
   echo 'export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' >> ~/.bashrc
   source ~/.bashrc
   ```

3. **Download & Install EFM** (latest 2.x from Cloudera archive — use your licensed repo or public evaluation):
   ```bash
   mkdir -p /opt/cloudera/efm && cd /opt/cloudera/efm
   # Example for latest tarball (replace with your version/link)
   wget https://archive.cloudera.com/p/cem/2.x/...
   tar -xzf efm-*.tar.gz
   ln -s efm-* current
   ```

4. **Configure** (`/opt/cloudera/efm/current/conf/efm.properties`):
   - Set DB connection, port `10090`, etc.
   - Enable Prometheus metrics endpoint (`efm.actuator.prometheus`).
   - Point to your future CSO Kafka if you want EFM to ingest edge data.

5. **Start EFM**:
   ```bash
   sudo /opt/cloudera/efm/current/bin/efm.sh start
   ```
   Access UI at `http://localhost:10090` (or your WSL IP). First login creates the admin user.

**WSL2 gotcha**: Port forwarding works automatically, but if you want Windows browser access, use `localhost:10090` or add a Windows firewall rule.

EFM is now your single pane of glass for designing flows, bundling ML models as assets, and pushing to MiNiFi agents.

### 3. Spin Up Minikube + Full Cloudera Streaming Operators (CSO) Stack

Follow **exactly** the steps in my Cloudera Community article “Cloudera Streaming Operators” and the YAMLs in the GitHub repo I linked above. I wrote it for macOS but it translates 1:1 to WSL2 Ubuntu.

Key commands (inside WSL2):
```bash
minikube start --cpus=6 --memory=16384 --driver=docker --kubernetes-version=stable
minikube addons enable ingress

# Create namespace + Cloudera creds secret (use your license.txt)
kubectl create ns cld-streaming
# ... docker-registry secret, cert-manager, helm login to container.repository.cloudera.com

# Install operators (Strimzi for Kafka, CSA, CFM) — see repo for exact helm install lines
# Apply kafka-eval.yaml + nodepool, schema-registry, surveyor, NiFi clusters, etc.
```

Once running you have:
- Kafka (CSM)
- Schema Registry
- Flink / SQL Stream Builder (CSA)
- NiFi (CFM)
- All exposed via Minikube ingress / NodePort.

### 4. CSO Observability: Prometheus + Grafana (My Dedicated Blog Guide)

Head to my blog post **[Observability with Cloudera Streaming Operators](https://cldr-steven-matison.github.io/blog/Observability-with-Cloudera-Streaming-Operators/)**.

In short:
- Install `kube-prometheus-stack` via Helm in the `cld-streaming` namespace.
- Add ServiceMonitors / PodMonitors for NiFi, Flink, Strimzi/Kafka.
- Deploy my pre-built Grafana dashboards (NiFi queue depths, Flink job latency, Kafka throughput, and a custom “Edge Metrics” one).
- EFM itself exposes `/efm/actuator/prometheus` — scrape it from the same Prometheus instance.

Your CSO Prometheus is now the central metrics sink for the entire lab **and** every MiNiFi agent.

### 5. Deploy MiNiFi C++ Agents from EFM (The Fun Part)

In EFM UI:
1. Design your flow (or import one).
2. Add **assets** (your TensorFlow/ONNX models, Python scripts, etc.).
3. Create a **Class** for each target environment (Windows C++, Docker, K8s, Jetson).
4. Generate the **one-line installer command** (new in recent EFM — game changer).

#### Target 1: Native Windows C++ Agent (on the Windows host)
Run the EFM-generated MSI command in an elevated PowerShell on Windows. It downloads the agent, registers with EFM via C2, pulls the flow + models, and starts.

#### Target 2: Docker
Use the official MiNiFi C++ Docker base (or build your own from the tarball). Mount the flow config and models:
```dockerfile
FROM cloudera/minifi-cpp:latest
COPY flow.yml /opt/minifi/config/flow.yml
COPY models/ /opt/minifi/models/
CMD ["/opt/minifi/bin/minifi.sh"]
```
Deploy via `docker run` or `docker-compose` on any host (including Windows Docker Desktop).

#### Target 3: Kubernetes (inside your Minikube or any K8s)
Deploy as a Deployment + Service. Example YAML (adapt from my CSO repo style):
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minifi-edge
spec:
  template:
    spec:
      containers:
      - name: minifi
        image: your-minifi-cpp-image
        volumeMounts:
        - name: flow
          mountPath: /opt/minifi/config
        - name: models
          mountPath: /opt/minifi/models
      volumes:
      - name: flow
        configMap:
          name: edge-flow
      - name: models
        secret:  # or configmap for models
          secretName: jetson-models
```
Add a ServiceMonitor so Prometheus auto-scrapes the `/metrics` endpoint.

#### Target 4: NVIDIA Jetson Orin Nano (Edge AI)
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

### Troubleshooting & Pro Tips (from my own lab)

- WSL2 memory pressure → give Minikube 16GB+.
- Jetson Docker GPU passthrough: `--runtime=nvidia --gpus all`.
- MiNiFi C++ on ARM: If the official binary doesn’t exist, build from Apache MiNiFi C++ source with aarch64 toolchain (I have a branch in my GitHub if you need it).
- Security: In production replace self-signed certs and add mTLS between EFM ↔ agents.

That’s it — a fully functional local Edge AI + streaming lab that mirrors real enterprise deployments.  

Drop a comment on the Cloudera Community thread or hit me up on LinkedIn if you want the exact YAML bundles or a video walk-through. I’ll keep updating this post as new EFM/MiNiFi versions drop.

Happy flowing (and inferencing)!  
— Steven Matison  
*(All links, repos, and dashboards are in my GitHub pages and the Cloudera Community article referenced above.)*