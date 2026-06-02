**Cloudera Edge Flow Manager (EFM) with Jetson Orin Nano for AI at the Edge**

Hey folks, Steven Matison here. If you’ve been following my Cloudera Community posts, my GitHub pages at [cldr-steven-matison.github.io](https://cldr-steven-matison.github.io/), or the fresh content now flowing to [stevenmatison.com](https://stevenmatison.com), you know I’m all about making complex streaming, flow management, and edge AI setups actually *work* on real hardware — Windows, mac, ubuntu, docker, kubernetes, and now a new NVIDIA Jetson Orin Nano.  

Today we’re going deep: with local lab for **Cloudera Edge Flow Manager (EFM / CEM)**, next to the full **Cloudera Streaming Operator (CSO)** stack (CFM + CSM + CSA) on Minikube Kubernetes, and then deploying **MiNiFi C++ agents** to NVIDIA Jetson Orin Nano.  

The goal? Design ai enabled nifi flows + ML model assets once in EFM, push them to edge agents, execute custom models *inside* MiNiFi on the Jetson, and ship system + processor + model metrics straight to the Prometheus instance living inside the CSO stack. All of it documented exactly the way I like — repeatable, with every command, and all the gotchas spelled out.

This post directly extends:
- My full **Cloudera Streaming Operators on Minikube** guide on the Cloudera Community (and the companion repo).
- My **Observability with Cloudera Streaming Operators** blog (Prometheus + Grafana for NiFi, Kafka, Flink).
- My **[MiNiFi Kubernetes Playfround](https://github.com/cldr-steven-matison/MiNiFi-Kubernetes-Playground)** for testing MiNiFi
- Official Cloudera CEM/EFM and MiNiFi C++ docs (with my WSL2/Windows/Jeston tweaks).

Let’s dive in.

### Install Cloudera Edge Flow Manager (EFM) Standalone in WSL2 Ubuntu

EFM is Java-based and runs cleanly on Ubuntu 22.04/24.04 inside WSL2. Follow the official standalone path (no Cloudera Manager needed for a lab).

**Step-by-step EFM Install**

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

