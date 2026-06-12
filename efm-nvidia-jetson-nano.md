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
[ i need to work on this, more than once my efm state is blown away,  i even have lost stuff,  not sure if i blew it away or if maybe OOM or too cluster too busy -  after doing a re-roll of EFM my last test, all classes were gone ]

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
get new yaml and configmap
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

  This section was original short enough to be in-line, but after taking the work stream into a sidequest it became its own doc.  


  [Installing EFM Binaries for Windows, Linux, and Nividia](efm-binaries.md).


###  Restart EFM

After installing binaries be sure to restart EFM.

```bash
kubectl rollout restart deployment/efm -n cld-streaming
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
```

### Expose EFM for Easy Access

```bash
minikube tunnel
```

[http://127.0.0.1:10090/efm/ui](http://127.0.0.1:10090/efm/ui)

[ I need to update this, we moved to the windows host IP for efm to be accessible to Jetson ]

Open that URL in your browser — you should land on the EFM login screen.

Now create a class and you can get to the Deploy Agent CLI Command Screen to verify all of the binaries are there.

[ screen shot here ]

Go ahead and Grab the Linux agent cli code:
 
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
 http://192.168.1.121:10090/efm/api/agent-deployer/script | bash -
```


Now that we have an agent code, we will wrap that up into a docker deployed kubernetes pod.  

First pull the docker image we need:

```bash
eval $(minikube docker-env)
docker pull --platform linux/amd64 ubuntu:22.04
```


Next create `minifi-agent-pod.yaml`

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: minifi-agent-k8s
  namespace: cld-streaming
spec:
  containers:
  - name: minifi
    image: ubuntu:22.04
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c"]
    args:
    - |
      apt-get update && apt-get install -y curl tar python3 python3-pip python3-venv
      ln -s /usr/bin/python3 /usr/bin/python || true
      
      curl -L \
       -d agentClass=KubernetesPod \
       -d agentIdentifier=e99e45f5-70f5-4847-af76-4f620b764aa9 \
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
      
      tail -f /dev/null                                
```

Apply the Agent Pod:

```bash
kubectl apply -f minifi-agent-pod.yaml
kubectl wait --for=condition=ready pod minifi-agent-test -n cld-streaming --timeout=60s\nkubectl logs minifi-agent-test -n cld-streaming
kubectl logs minifi-agent-test -n cld-streaming -f
kubectl exec -it minifi-agent-test -n cld-streaming -- tail -f /nifi-minifi-cpp-1.26.02/logs/minifi-app.log
```

Now Minifi should be up in the pod and the agent should appear in the `test` Class in the EFM Dashboard.  Win!


### 3. Deploy the MiNiFi C++ Agent on the Jetson Orin Nano


Generate a **unique** agent identifier test class `NvidiaNano` and fetch the CLI command for arch64:

```bash
curl -L \
 -d agentClass=jetson-edge \
 -d agentIdentifier=$(cat /proc/sys/kernel/random/uuid) \
 -d agentType=cpp \
 -d agentVersion=1.26.02 \
 -d autoConfigureSecurity=false \
 -d baseUrl=http%3A%2F%2F127.0.0.1%3A46663%2Fefm%2Fapi \
 -d hbPeriod=5000 \
 -d osArch=linuxaarch64 \
 -d serviceName=minifi \
 -d serviceUser=minifi \
 -d trustSelfSignedCertificates=false \
 http://192.168.1.121:46663/efm/api/agent-deployer/script | bash -
```

**Replace** `<YOUR_LAB_HOST_IP>` with your actual lab machine IP.

The script will:
- Contact EFM
- Download the **linux-arm64** binary + extra extensions
- Extract and configure MiNiFi C++
- Start the agent as a background process.

### 4. Verify the Agent Is Running

```bash
# Find the install location (usually created in current directory or /opt)
ls -l minifi-1.26.02* || echo "Check ~/ or /opt/minifi*"

# Tail the log
tail -f minifi-1.26.02/logs/minifi-app.log
```

The agent should appear almost immediately in the EFM UI → **Monitor** → **Agents** (under class `test`).

[ I got all the binaries working at this point metrics are ready ]

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

**Metrics to Prometheus**:
MiNiFi C++ has native Prometheus support. In `minifi.properties`:
```properties
# Enable Prometheus
nifi.c2.enable.metrics=true
nifi.c2.metrics.publisher=prometheus
nifi.c2.metrics.publisher.prometheus.port=9092
```
The agent registers itself with EFM, EFM knows the Prometheus scrape target, or you add a static scrape in your CSO Prometheus config. My Grafana dashboard will now show Jetson CPU/GPU/temp + model inference latency + flow throughput.

### Testing Nvidia Jetson

Flow

Python Script

Curl Command

Kafka Messages
