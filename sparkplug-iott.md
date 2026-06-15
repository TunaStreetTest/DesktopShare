### Overall Architecture
- **Mosquitto MQTT Broker** → deployed in Minikube (central message bus).
- **NVIDIA Jetson** → Edge host running your IoT simulator (publishes Sparkplug B messages).
- **CFM (Cloudera Flow Management)** → Runs the NiFi flow that consumes Sparkplug B via the new `ConsumeMQTTIIoT` / `MQTTIIoTReader` components and converts to JSON using `ConvertRecord`.

---

### Phase 1: Deploy Mosquitto MQTT in Minikube

**Goal**: Get a reliable MQTT broker inside the cluster that both the Jetson (edge) and NiFi can reach.


1. Create a namespace:
   ```bash
   kubectl create namespace mqtt
   ```

2. Create a **ConfigMap** for `mosquitto.conf` (basic config for testing):
   ```yaml
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: mosquitto-config
     namespace: mqtt
   data:
     mosquitto.conf: |
       listener 1883
       allow_anonymous true
       persistence true
       persistence_location /mosquitto/data/
       log_dest stdout
   ```

3. Deploy Mosquitto (Deployment + Service):
   ```yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: mosquitto
     namespace: mqtt
   spec:
     replicas: 1
     selector:
       matchLabels:
         app: mosquitto
     template:
       metadata:
         labels:
           app: mosquitto
       spec:
         containers:
         - name: mosquitto
           image: eclipse-mosquitto:2.0.21
           ports:
           - containerPort: 1883
           volumeMounts:
           - name: config
             mountPath: /mosquitto/config
           - name: data
             mountPath: /mosquitto/data
         volumes:
         - name: config
           configMap:
             name: mosquitto-config
         - name: data
           emptyDir: {}
   ---
   apiVersion: v1
   kind: Service
   metadata:
     name: mosquitto
     namespace: mqtt
   spec:
     selector:
       app: mosquitto
     ports:
     - port: 1883
       targetPort: 1883
     type: NodePort   # Easy access from Jetson / host
   ```

4. Apply and verify:
   ```bash
   kubectl apply -f mosquitto.yaml
   kubectl get svc -n mqtt
   ```

   **Note the NodePort** (e.g., `30000+` range). From outside the cluster you can connect to `minikube ip:NodePort`.


---

### Phase 2: NVIDIA Jetson as Edge Host + Sparkplug B Simulator

**Goal**: Simulate realistic Sparkplug B publishing from the edge.

**Recommended library**: **PySparkplug** (clean, modern Python implementation)

```bash
pip install pysparkplug paho-mqtt
```

**Example simulator script** (`sparkplug_simulator.py`):

```python
import time
from pysparkplug import Client, EdgeNode, Device, Metric, DataType

BROKER = "tcp://<minikube-ip>:<nodeport>"   # e.g. tcp://192.168.49.2:30001
NAMESPACE = "spBv1.0"
GROUP_ID = "FactoryLine1"
EDGE_NODE_ID = "Jetson-01"
DEVICE_ID = "SensorArray-01"

client = Client(BROKER)
edge_node = EdgeNode(client, NAMESPACE, GROUP_ID, EDGE_NODE_ID)
device = Device(edge_node, DEVICE_ID)

# Birth certificates (required in Sparkplug B)
edge_node.publish_birth()
device.publish_birth([
    Metric("Temperature", DataType.Float, 23.5),
    Metric("Humidity", DataType.Float, 45.2),
    Metric("Status", DataType.String, "Running"),
])

print("Edge Node and Device online. Publishing data...")

while True:
    device.publish_data([
        Metric("Temperature", DataType.Float, 23.5 + (time.time() % 5)),
        Metric("Humidity", DataType.Float, 45.2),
    ])
    time.sleep(5)
```

Run it on the Jetson:
```bash
python sparkplug_simulator.py
```
---

### Phase 3: Build the NiFi Flow in CFM (Sparkplug B Ingestion)

**Goal**: Consume Sparkplug B messages and convert them to JSON using the new components.

#### Sparkplug Flow
Use the **new dedicated processor**:
- **ConsumeMQTTIIoT** (new in recent CFM)

This processor can act as a **Primary Host Application**:
- Sends its own online/offline states
- Can request Rebirth messages from edge nodes


**Recommended Flow Structure**:

```
ConsumeMQTTIIoT
    │
    ▼
ConvertRecord (Record Reader = MQTTIIoTReader or built-in Sparkplug parsing)
    │
    ▼
[RouteOnAttribute / RouteOnContent]   ← Optional (filter by message type: NBIRTH, NDATA, NDEATH, etc.)
    │
    ▼
PublishKafka
```

**Key Configuration Points**:

1. **MQTTIIoTReader** Controller Service (if using Option B):
   - Broker URI: `tcp://mosquitto.mqtt.svc.cluster.local:1883` (or external NodePort)
   - Enable Sparkplug B parsing

2. **ConsumeMQTTIIoT**:
   - Configure as Primary Host if you want rebirth request capability.
   - Set topic filter: `spBv1.0/#`

3. **ConvertRecord**:
   - Record Reader → Use the new `MQTTIIoTReader` service (or the built-in Sparkplug support).
   - Record Writer → **JSONRecordSetWriter** (or Avro, Parquet, etc.)

This will turn the binary Protobuf Sparkplug payload into clean, queryable JSON.

---

### Phase 4: End-to-End Testing & Validation

1. Start Mosquitto in Minikube.
2. Run the Sparkplug simulator on the Jetson.
3. Start the NiFi flow.
4. Verify in NiFi:
   - Check **Provenance** for incoming flowfiles.
   - Use `LogAttribute` to see the converted JSON.
5. Test key Sparkplug behaviors:
   - Edge node birth → `NBIRTH`
   - Data updates → `NDATA`
   - Disconnect → `NDEATH`
   - Rebirth request from NiFi (if using `ConsumeMQTTIIoT` as Primary Host)

---

