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


### Create the EFM Database & User in Your Existing SSB Postgres

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

### Create the EFM Database Password Secret

```bash
kubectl create secret generic efm-db-pass \
  --from-literal=password=efm_password \
  --namespace cld-streaming
```


### Create a PersistentVolumeClaim for Agent Binaries (so they survive pod restarts)

Create `efm-agent-binaries-pvc.yaml`:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efm-agent-binaries
  namespace: cld-streaming
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi   # plenty for several versions of Java + C++
  storageClassName: standard   # Minikube default
```

Apply it:

```bash
kubectl apply -f efm-agent-binaries-pvc.yaml
```


### Pull the Official EFM Docker Image into Minikube

```bash
eval $(minikube docker-env)
docker login container.repo.cloudera.com
docker pull container.repo.cloudera.com/cloudera/efm:2.3.1.0-2
```

Use the exact tag that matches your CSO / CEM entitlement — 2.2.0.0-86 is the one I’m running in the lab right now. Check your Cloudera archive for the latest matching version.

### EFM Deployment YAML

Create these files in your working directory:

`efm-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efm-agent-binaries
  namespace: cld-streaming
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: standard

````

`efm-deployment.yaml`

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
      - name: cloudera-registry
      containers:
      - name: efm
        image: container.repo.cloudera.com/cloudera/efm:2.3.1.0-2
        ports:
        - containerPort: 10090
        - containerPort: 9092
        env:
        - name: EF_DB_URL
          value: "jdbc:postgresql://ssb-postgresql.cld-streaming.svc:5432/efm"
        - name: EF_REGISTRY_URL
          value: "http://nifi-registry-edge-svc.cfm-streaming.svc:18080"
        - name: EF_REGISTRY_ENABLED
          value: "true"
        - name: JAVA_OPTS
          value: "-Dspring.datasource.driver-class-name=org.postgresql.Driver -Def.db.driver.class.name=org.postgresql.Driver"
        - name: EF_JAVA_OPTS
          value: "-Dspring.datasource.driver-class-name=org.postgresql.Driver -Def.db.driver.class.name=org.postgresql.Driver"
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
              name: efm-encryption
              key: encryption.password
        resources:
          requests:
            cpu: "250m"
            memory: "4Gi"
          limits:
            cpu: "250m"
            memory: "4Gi"
        # === Agent binaries PVC mount (confirmed correct path for 2.3.x Docker image) ===
        volumeMounts:
        - name: agent-binaries
          mountPath: /opt/efm/agent-deployer/binaries
      # === PVC volume definition (must be at pod spec level, sibling to containers) ===
      volumes:
      - name: agent-binaries
        persistentVolumeClaim:
          claimName: efm-agent-binaries

---

apiVersion: v1
kind: Service
metadata:
  name: efm
  namespace: cld-streaming
  labels:
    app: efm
spec:
  type: LoadBalancer
  ports:
  - port: 10090
    targetPort: 10090
    protocol: TCP
    name: efm-ui
  - port: 9092
    targetPort: 9092
    protocol: TCP
    name: metrics
  selector:
    app: efm
```

**Create the encryption secret first** (if you haven’t already):

```bash
kubectl create secret generic efm-encryption \
  --from-literal=encryption.password=SuperSecretEFMKey123! \
  --namespace cld-streaming
```

Apply it:

```bash
kubectl apply -f efm-pvc.yaml
kubectl apply -f efm-deployment.yaml
```

### Download Compatible MiNiFi Java & C++ Binaries (Cloudera archive)

You need binaries that match EFM 2.3.x compatibility:

- **MiNiFi Java** → 2.24.08 (or any 2.24.x / 1.23+)
- **MiNiFi C++** → 1.26.02 (best for Jetson Docker workflow)

Log in to your Cloudera account (same credentials you used for `docker login container.repo.cloudera.com`) and download from:

- Java: `https://archive.cloudera.com/p/cem-agents/...` (search “nifi-minifi-java” under CEM agents)
- C++ Linux: `https://archive.cloudera.com/p/cem-agents/1.26.02/ubuntu24/apt/tars/nifi-minifi-cpp/nifi-minifi-cpp-1.26.02-b30-bin-linux.tar.gz` (and the extra-extensions + python-components if you want AI/ExecutePython)

**Rename exactly as EFM expects** (one file per version directory):

On your laptop/host, create a temp folder and prepare:

```bash
mkdir -p ~/efm-binaries/java/linux/2.24.08
mkdir -p ~/efm-binaries/cpp/linux/1.26.02

# Example commands (replace with your actual downloaded files)
cp /path/to/nifi-minifi-java-2.24.08-bin.tar.gz ~/efm-binaries/java/linux/2.24.08/minifi.tar.gz
cp /path/to/nifi-minifi-cpp-1.26.02-b30-bin-linux.tar.gz ~/efm-binaries/cpp/linux/1.26.02/minifi.tar.gz
```

(If you want extra C++ extensions for TensorRT/ONNX/Python on Jetson, also copy the extra tar/zip and place it in the same version dir — EFM will serve it.)

### Copy Binaries into the EFM Pod (via PVC)

```bash
# Copy the whole tree into the pod
kubectl cp ~/efm-binaries/java -n cld-streaming $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}'):/opt/efm/agent-deployer/binaries/java
kubectl cp ~/efm-binaries/cpp -n cld-streaming $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}'):/opt/efm/agent-deployer/binaries/cpp
```


need to adjust command above, here is history to get it to work, had to add pvc, get the binaries to right place

```bash
steven.matison@FTF3XR2065 ~ % history
 1020  mkdir -p ~/efm-binaries/cpp/linux/1.26.02\nmv ~/efm-binaries/cpp/cpp/linux/1.26.02/minifi.tar.gz ~/efm-binaries/cpp/linux/1.26.02/ 2>/dev/null || true\nrm -rf ~/efm-binaries/cpp/cpp
 1021  kubectl delete -f efm-deployment.yaml\nkubectl apply -f efm-deployment.yaml
 1022  kubectl exec -it $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}') -n cld-streaming -- mkdir -p /opt/efm/agent-deployer/binaries\nkubectl cp ~/efm-binaries/cpp -n cld-streaming $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}'):/opt/efm/agent-deployer/binaries/cpp
 1023  kubectl exec -it $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}') -n cld-streaming -- find /opt/efm/agent-deployer/binaries -type f
 1024  kubectl exec -it $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}') -n cld-streaming -- env
 1025  kubectl exec -it $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}') -n cld-streaming -- find / -name "agent-deployer" 2>/dev/null
 1026  nano efm-deployment.yaml
 1027  kubectl delete -f efm-deployment.yaml\nkubectl apply -f efm-deployment.yaml
 1028  kubectl delete -f efm-deployment.yaml\nkubectl apply -f efm-deployment.yaml
 1029  kubectl delete -f efm-deployment.yaml\nkubectl apply -f efm-deployment.yaml
 1030  kubectl describe pod -l app=efm -n cld-streaming
 1031  nano efm-pvc.yaml
 1032  kubectl apply -f efm-pvc.yaml
 1033  kubectl exec -it $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}') -n cld-streaming -- mkdir -p /opt/efm/efm-2.3.1.0-2/agent-deployer/binaries
 1034  kubectl cp ~/efm-binaries/cpp -n cld-streaming $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}'):/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp
 1035  kubectl exec -it $(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}') -n cld-streaming -- find /opt/efm/efm-2.3.1.0-2/agent-deployer/binaries -type f
```


Wait for EFM pod to be fully ready (important!)

```bash

kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
```

Restart EFM once so it immediately sees the new binaries (optional but recommended)

```bash
kubectl rollout restart deployment/efm -n cld-streaming
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
```

Verify inside the pod:

```bash
kubectl exec -it <efm-pod-name> -n cld-streaming -- ls -lR /opt/efm/agent-deployer/binaries
```

You should now see the full structure with `minifi.tar.gz` files.

### Expose EFM for Easy Access

```bash
minikube tunnel
```

[http://127.0.0.1:10090/efm/ui](http://127.0.0.1:10090/efm/ui)


Open that URL in your browser — you should land on the EFM login screen.


Now create a class and you can get to the Deploy Agent CLI Command Screen to verify cpp v 1.26.02 binary is there.

 
```bash
curl -L \
 -d agentClass=test \
 -d agentIdentifier=b2c63cf5-de86-4b62-8d17-cad369af68ad \
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

Now that we have an agent code,  thats wrap that up with AI into a kubernetes pod:

create `minifi-agent-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: minifi-agent-test
  namespace: cld-streaming
spec:
  containers:
  - name: minifi
    image: ubuntu:22.04
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c"]
    args:
    - |
      apt-get update && apt-get install -y curl tar
      curl -L \
       -d agentClass=test \
       -d agentIdentifier=b2c63cf5-de86-4b62-8d17-cad369af68ad \
       -d agentType=cpp \
       -d agentVersion=1.26.02 \
       -d autoConfigureSecurity=false \
       -d baseUrl=http%3A%2F%2Fefm.cld-streaming.svc%3A10090%2Fefm%2Fapi \
       -d hbPeriod=5000 \
       -d osArch=linux \
       -d serviceName=minifi \
       -d serviceUser=root \
       -d trustSelfSignedCertificates=false \
       http://efm.cld-streaming.svc:10090/efm/api/agent-deployer/script | bash -
      tail -f /dev/null%                                      
```

Before I could get c++ agent to work in the pod I had to do this:

```bash
eval $(minikube docker-env)
docker pull --platform linux/amd64 ubuntu:22.04
```

Apply the Agent Pod:

```bash
kubectl apply -f minifi-agent-pod.yaml
kubectl wait --for=condition=ready pod minifi-agent-test -n cld-streaming --timeout=60s\nkubectl logs minifi-agent-test -n cld-streaming
kubectl logs minifi-agent-test -n cld-streaming -f
kubectl exec -it minifi-agent-test -n cld-streaming -- tail -f /nifi-minifi-cpp-1.26.02/logs/minifi-app.log
```

Now Minifi should be up in the pod and the agent should appear in the Test Class in the EFM Dashboard.  Win!

### Add EFM to Your CSO Prometheus Observability

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

### Deploy MiNiFi C++ Flows and Resources from EFM

In EFM UI:

1. Design your flow (or import one).
2. Add **assets** (your TensorFlow/ONNX models, Python scripts, etc.).

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

