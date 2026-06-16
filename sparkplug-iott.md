### Overall Architecture
- **Mosquitto MQTT Broker** → deployed in Minikube (central message bus).
- **NVIDIA Jetson** → Edge host running your IoT simulator (publishes simulated Sparkplug B messages).
- **NVIDIA Jetson** → Edge host streaming Environment Sensor data to Inference Model to capture Extreme Sensor Values → sound a local alarm on exceptions.
- **EFM (Edge Flow Manager) / MiNiFi** → MiNiFi flow consumes Sparkplug B via the new `ConsumeMQTTIIoT` / `MQTTIIoTReader` and uses `ExecuteScript` for Edge Inference Model.
- **CFM (Cloudera Flow Management) / NiFi** → Runs a NiFi flow that consumes Sparkplug B via the new `ConsumeMQTTIIoT` / `MQTTIIoTReader` components and converts to JSON using `ConvertRecord`.

---

### Phase 1: Deploy Mosquitto MQTT in Minikube

**Goal**: Get a reliable MQTT broker inside the cluster that both the Jetson (edge) and NiFi can reach.


1. Create a namespace:
   ```bash
   kubectl create namespace mqtt
   ```

2. Create a **ConfigMap** for `mosquitto-configMap.yaml`:
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

3. Deploy Mosquitto (Deployment + Service) `mosquitto.yaml`:
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
   kubectl apply -f mosquitto-configMap.yaml
   kubectl apply -f mosquitto.yaml
   kubectl get svc -n mqtt
   ```

   **Note the NodePort** (e.g., `30000+` range). From outside the cluster you can connect to `minikube ip:NodePort`.

```bash
kubectl port-forward pod/mosquitto-b7876bbf7-h8c67 1883:1883 -n mqtt
```

---

### Phase 2: NVIDIA Jetson as Edge Host + Sparkplug B Simulator

**Goal**: Simulate realistic Sparkplug B publishing from the edge.

**Recommended library**: **PySparkplug**

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

### Phase 2: NVIDIA Jetson Setup + Real Sensor Integration (Environment Sensors Module for Jetson Nano, I2C Bus, with 1.3inch OLED Display)

#### 2.1 Hardware Setup
1. Plug the **Waveshare Environment Sensor** module directly onto the Jetson Nano’s 40-pin GPIO header.
2. Power on the Jetson.

#### 2.2 Enable I2C on Jetson
Run this command and enable **I2C** (usually on bus 0 or 1):

```bash
sudo /opt/nvidia/jetson-io/jetson-io.py
```

Or use the graphical tool if available. Reboot after enabling I2C.

#### 2.3 Install Required Libraries

```bash
sudo apt update
sudo apt install python3-pip python3-dev libatlas-base-dev -y

pip3 install adafruit-circuitpython-bme280 pysparkplug paho-mqtt
```

> **Note**: We’re using the reliable `adafruit-circuitpython-bme280` library for the BME280 sensor on the Waveshare module (it works very well on Jetson).

#### 2.4 Updated Python Script (Real Sensor + Sparkplug B)

Create a new file on the Jetson:

```bash
nano sparkplug_jetson_sensor.py
```

Paste the following code:

```python
import time
import board
import busio
from adafruit_bme280 import basic as adafruit_bme280
from pysparkplug import Client, EdgeNode, Device, Metric, DataType

# ====================== CONFIGURATION ======================
BROKER = "tcp://<MINIKUBE-IP>:<NODEPORT>"     # ← Change this!
NAMESPACE = "spBv1.0"
GROUP_ID = "FactoryLine1"
EDGE_NODE_ID = "Jetson-01"
DEVICE_ID = "EnvSensor-01"
PUBLISH_INTERVAL = 5                          # seconds
# ===========================================================

# Initialize I2C and BME280 sensor (Waveshare module uses address 0x76)
i2c = busio.I2C(board.SCL, board.SDA)
bme280 = adafruit_bme280.Adafruit_BME280_I2C(i2c, address=0x76)

print("BME280 sensor initialized successfully.")

# ====================== SPARKPLUG SETUP ======================
client = Client(BROKER)
edge_node = EdgeNode(client, NAMESPACE, GROUP_ID, EDGE_NODE_ID)
device = Device(edge_node, DEVICE_ID)

# Publish Birth Certificates (required in Sparkplug B)
edge_node.publish_birth()
device.publish_birth([
    Metric("Temperature", DataType.Float, 0.0),
    Metric("Humidity", DataType.Float, 0.0),
    Metric("Pressure", DataType.Float, 0.0),
])

print(f"Edge Node '{EDGE_NODE_ID}' and Device '{DEVICE_ID}' are now online.")
print("Publishing real sensor data via Sparkplug B...\n")

# ====================== MAIN LOOP ======================
while True:
    try:
        temperature = round(bme280.temperature, 2)
        humidity = round(bme280.humidity, 2)
        pressure = round(bme280.pressure, 2)

        # Publish current values as NDATA
        device.publish_data([
            Metric("Temperature", DataType.Float, temperature),
            Metric("Humidity", DataType.Float, humidity),
            Metric("Pressure", DataType.Float, pressure),
        ])

        print(f"Published → Temp: {temperature}°C | Humidity: {humidity}% | Pressure: {pressure} hPa")

    except Exception as e:
        print(f"Error reading sensor or publishing: {e}")

    time.sleep(PUBLISH_INTERVAL)
```

**Important**: Replace `<MINIKUBE-IP>:<NODEPORT>` with your actual Mosquitto address (example: `192.168.49.2:30001`).

#### 2.5 Run the Script

```bash
python3 sparkplug_jetson_sensor.py
```

You should see output like:
```
Published → Temp: 24.35°C | Humidity: 48.12% | Pressure: 1012.45 hPa
```

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


### Phase 5: Edge Intelligence – Sparkplug B + MiNiFi + TensorRT on Jetson (The "To The Moon" Demo)

This phase moves real intelligence to the **edge**. Instead of sending every sensor reading to the central NiFi cluster, we run a lightweight **MiNiFi** flow **directly on the Jetson** that:

- Consumes its own Sparkplug B messages locally using `ConsumeMQTTIIoT`
- Runs a **custom `ExecuteScript`** processor powered by **TensorRT**
- Evaluates sensor data for extreme conditions in real time
- Triggers a physical **alarm/buzzer** when the temperature gets too hot

This creates a very impressive demo: **Edge AI + Sparkplug B + Local Actuation**.

---

### 5.1 Architecture Overview

```
Jetson (Edge)
├── Waveshare Environment Sensor → Python script publishes Sparkplug B
├── MiNiFi Agent (running locally)
│   ├── ConsumeMQTTIIoT (subscribes to its own data)
│   ├── ExecuteScript (Python + TensorRT)
│   │   └── Detects "extremities" (e.g. temp > threshold)
│   └── GPIO Control → Sounds Buzzer if too hot
│
└── Still publishes to central Mosquitto → Central NiFi (CFM)
```

This gives you **both**:
- Local real-time reaction (buzzer)
- Centralized processing and downstream delivery of messages to NiFi

---

### 5.2 MiNiFi Flow Design on Jetson

**Flow structure on MiNiFi:**

```
ConsumeMQTTIIoT
    │
    ▼
ExecuteScript (Python)
    │   ├── Read sensor metrics
    │   ├── Run TensorRT inference (or simple rules)
    │   ├── If temperature is extreme → Trigger GPIO buzzer
    │   └── Route based on result
    │
    ▼
RouteOnAttribute
    ├── Read sensor metrics
    │   ├── Run TensorRT inference (or simple rules)
    │   ├── If temperature is extreme → Trigger GPIO buzzer
    │   └── Route based on result
    │   │
    │   ▼
    │   Sound Alarm → Trigger GPIO buzzer
    ▼
PublishKafka

```

**Key Processors needed on MiNiFi:**
- `ConsumeMQTTIIoT` (or `ConsumeMQTT` + `MQTTIIoTReader`)
- `ExecuteScript` (Python)
- `RouteOnAttribute`
- `PublishKafka`

---

### 5.3 Custom ExecuteScript Example (Python + GPIO + Threshold)

Here’s a starter script you can use inside `ExecuteScript`:

```python
import sys
import json
import Jetson.GPIO as GPIO
from pysparkplug import ...   # if needed

# GPIO Setup
BUZZER_PIN = 7   # Physical pin 7 (GPIO4)
GPIO.setmode(GPIO.BOARD)
GPIO.setup(BUZZER_PIN, GPIO.OUT)

def main():
    flowfile = sys.stdin.read()
    data = json.loads(flowfile)

    # Extract temperature from Sparkplug-converted JSON
    temperature = data.get("Temperature", 0)

    is_extreme = temperature > 35.0   # ← Your threshold

    if is_extreme:
        GPIO.output(BUZZER_PIN, GPIO.HIGH)
        print("ALERT: Temperature too high! Buzzer activated.")
    else:
        GPIO.output(BUZZER_PIN, GPIO.LOW)

    # You can also add TensorRT inference here later
    # Example: model inference on temperature + other features

    sys.stdout.write(json.dumps({"is_extreme": is_extreme, "temperature": temperature}))

if __name__ == "__main__":
    main()
```

### Phase 5.5 – AI at the Edge: Tiny Neural Network + ONNX Runtime + TensorRT

**Goal**  
Run real GPU-accelerated AI inference directly on the Jetson using the sensor data, while keeping the model small and practical for edge deployment.

**Approach**  
Instead of large vision models, we train a **very small neural network** (Autoencoder for anomaly detection) on tabular sensor data. We then optimize and run it using **TensorRT** on the Jetson GPU via **ONNX Runtime**.

**High-Level Workflow**

1. **Train** a tiny Autoencoder (or simple classifier) on a PC/laptop using PyTorch (training takes only a few minutes).
2. **Export** the model to ONNX format.
3. **Convert** the ONNX model to a TensorRT engine on the Jetson (one-time step using `trtexec` with FP16).
4. **Run inference** on the Jetson using **ONNX Runtime with TensorRT Execution Provider** (automatically uses the GPU).
5. Integrate the inference into MiNiFi’s **`ExecuteScript`** processor.
6. Trigger the buzzer and/or generate alerts when the model detects an anomaly/extreme condition.

**Key Benefits for the Demo**
- Actually uses the **Jetson GPU** for AI inference (proper TensorRT acceleration).
- Very lightweight and fast (suitable for real-time edge processing).
- Clean integration with Sparkplug B via `ConsumeMQTTIIoT`.
- More intelligent than simple rules (learns normal sensor behavior).
- Easy to extend later with more features or a classifier.

**Integration Points**
- MiNiFi flow on Jetson: `ConsumeMQTTIIoT` → `ExecuteScript` (Python + ONNX Runtime + TensorRT) → GPIO control (buzzer) + optional alert publishing.
- Still forwards data to central Mosquitto → NiFi cluster for full processing.

---

### 5.6 Full Updated Flow Summary

| Layer              | What Runs Where              | Purpose |
|--------------------|------------------------------|--------|
| **Edge (Jetson)**  | Python publisher             | Read Waveshare sensor → Sparkplug B |
| **Edge (Jetson)**  | MiNiFi + ConsumeMQTTIIoT     | Local consumption of Sparkplug data |
| **Edge (Jetson)**  | ExecuteScript + TensorRT     | Detect extremes + trigger buzzer |
| **Cloud/Cluster**  | Central NiFi (CFM)           | Full processing, storage, dashboards |

---


### Appendix

#### Session 1

In this session I wanted to quickly test mqtt works on minikube, deploy a test script and confirm a flow works with `ConsumeMqTT`, then deploy a Sparkplug B python and test `ConsumeMQTTIIoT`.

Sample Flow:  [SparkPlug](files/SparkPlug.json)

cat `mqtt_test_publisher.py`

```bash
import time
import json
import random
import paho.mqtt.client as mqtt

# Configuration
# Use "localhost" if you port-forwarded to your Mac. 
# Use the K8s service DNS string if running this script inside the cluster.
BROKER = "localhost" 
PORT = 1883
TOPIC = "test/sensor/data"

# Initialize client (compatible with paho-mqtt 2.x)
client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)

print(f"Connecting to Mosquitto broker at {BROKER}:{PORT}...")
try:
    client.connect(BROKER, PORT, 60)
except Exception as e:
    print(f"Connection failed: {e}. Did you forget to run kubectl port-forward?")
    exit(1)

client.loop_start()

print(f"Successfully connected! Publishing data to topic '{TOPIC}' every 2 seconds. Press Ctrl+C to stop.")

try:
    while True:
        # Simulate simple sensor data
        payload = {
            "device_id": "MacMockSensor-01",
            "temperature": round(random.uniform(20.0, 30.0), 2),
            "humidity": round(random.uniform(40.0, 60.0), 2),
            "timestamp": int(time.time())
        }

        # Publish data
        client.publish(TOPIC, json.dumps(payload))
        print(f"Published: {payload}")
        time.sleep(2)

except KeyboardInterrupt:
    print("\nStopping publisher...")
    client.loop_stop()
    client.disconnect()

```

Sample Output:

```bash
Connecting to Mosquitto broker at localhost:1883...
Successfully connected! Publishing data to topic 'test/sensor/data' every 2 seconds. Press Ctrl+C to stop.
Published: {'device_id': 'MacMockSensor-01', 'temperature': 22.43, 'humidity': 53.29, 'timestamp': 1781614422}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 24.88, 'humidity': 51.33, 'timestamp': 1781614424}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 21.82, 'humidity': 41.39, 'timestamp': 1781614426}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 26.19, 'humidity': 52.91, 'timestamp': 1781614428}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 25.82, 'humidity': 40.63, 'timestamp': 1781614430}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 26.36, 'humidity': 50.89, 'timestamp': 1781614432}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 20.41, 'humidity': 55.88, 'timestamp': 1781614434}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 24.39, 'humidity': 58.0, 'timestamp': 1781614436}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 22.87, 'humidity': 44.09, 'timestamp': 1781614438}
Published: {'device_id': 'MacMockSensor-01', 'temperature': 20.01, 'humidity': 52.25, 'timestamp': 178161444}
```

cat `sparkplug_test_publisher.py`
```bash
import time
import random
import paho.mqtt.client as mqtt
from pysparkplug import NBirth, NData, Metric, DataType, get_current_timestamp

# Configuration
BROKER = "localhost"
PORT = 1883
GROUP_ID = "MacLocalTest"
EDGE_NODE_ID = "Mac-Node-01"

# Manually construct specification-compliant Sparkplug B topics
TOPIC_NBIRTH = f"spBv1.0/{GROUP_ID}/NBIRTH/{EDGE_NODE_ID}"
TOPIC_NDATA = f"spBv1.0/{GROUP_ID}/NDATA/{EDGE_NODE_ID}"

# Initialize standard paho-mqtt client
client = mqtt.Client()
print(f"Connecting to Mosquitto broker at {BROKER}:{PORT}...")
client.connect(BROKER, PORT, 60)
client.loop_start()

# 1. Publish Node Birth Certificate (NBIRTH)
print("Publishing binary Sparkplug B NBIRTH payload...")
ts_birth = get_current_timestamp()
metrics_birth = (
    Metric(name="Temperature", datatype=DataType.FLOAT, value=22.0, timestamp=ts_birth),
    Metric(name="Humidity", datatype=DataType.FLOAT, value=50.0, timestamp=ts_birth),
)
nbirth_payload = NBirth(timestamp=ts_birth, seq=0, metrics=metrics_birth)
client.publish(TOPIC_NBIRTH, nbirth_payload.encode(), qos=1)

print("Node is ONLINE. Sending NDATA every 5 seconds. Press Ctrl+C to stop.")

seq = 1
try:
    while True:
        temp_val = round(random.uniform(20.0, 35.0), 2)
        humid_val = round(random.uniform(40.0, 60.0), 2)
        
        # 2. Publish Node Data (NDATA)
        ts_data = get_current_timestamp()
        metrics_data = (
            Metric(name="Temperature", datatype=DataType.FLOAT, value=temp_val, timestamp=ts_data),
            Metric(name="Humidity", datatype=DataType.FLOAT, value=humid_val, timestamp=ts_data),
        )
        ndata_payload = NData(timestamp=ts_data, seq=seq, metrics=metrics_data)
        
        client.publish(TOPIC_NDATA, ndata_payload.encode(), qos=1)
        print(f"Sent Sparkplug NDATA (Seq: {seq}) -> Temp: {temp_val} | Humid: {humid_val}")
        
        seq = (seq + 1) % 256  # Sparkplug sequence numbers loop 0-255
        time.sleep(5)

except KeyboardInterrupt:
    print("\nStopping script...")
    client.loop_stop()
    client.disconnect()

```

Sample Output:

```bash
Connecting to Mosquitto broker at localhost:1883...
Publishing binary Sparkplug B NBIRTH payload...
Node is ONLINE. Sending NDATA every 5 seconds. Press Ctrl+C to stop.
Sent Sparkplug NDATA (Seq: 1) -> Temp: 28.87 | Humid: 49.59
Sent Sparkplug NDATA (Seq: 2) -> Temp: 26.07 | Humid: 51.89
Sent Sparkplug NDATA (Seq: 3) -> Temp: 31.36 | Humid: 46.76
Sent Sparkplug NDATA (Seq: 4) -> Temp: 21.02 | Humid: 46.02
Sent Sparkplug NDATA (Seq: 5) -> Temp: 34.21 | Humid: 56.91
Sent Sparkplug NDATA (Seq: 6) -> Temp: 25.27 | Humid: 41.77
Sent Sparkplug NDATA (Seq: 7) -> Temp: 30.73 | Humid: 58.52
```


Terminal History
s
```terminal
source venv/bin/activate
pip install paho-mqtt
python mqtt_test_publisher.py
pip install pysparkplug
nano sparkplug_test_publisher.py  
```
