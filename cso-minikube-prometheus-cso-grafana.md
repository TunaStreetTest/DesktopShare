**End-to-End CSO Dashboard with Grafana – Detailed Action Plan**  
*(Fraud-Themed Custom Grafana Dashboard for Cloudera Streaming Operators)*  

This plan is **extremely detailed and fully actionable**. It assumes your full CSO + Prometheus + Grafana stack (from the landing page + Parts 1-3) is already running in minikube with the fraud pipeline active (NiFi flow feeding `txn1`/`txn2`/`txn_fraud`/`txn_panda_distance` → Kafka → SSB/Flink jobs selecting results and inserting `fraud_alerts`).  

All metric names come directly from the three parts you already built (Kafka JMX exporter, NiFi mTLS ServiceMonitor, Flink headless ServiceMonitor). You can copy-paste every query and config.  


### Phase 0: Quick Pre-Checks (5 minutes)
1. Confirm everything is live:  
   ```bash
   minikube service prometheus-grafana --namespace cld-streaming
   minikube service prometheus-kube-prometheus-prometheus --namespace cld-streaming
   ```
2. Open Grafana (http://localhost:xxxx), log in (`admin` / password from `kubectl get secret ...`).  
3. Verify data source “Prometheus” is connected and can query both namespaces (`cfm-streaming` + `cld-streaming`).  
4. In Prometheus UI, run these test queries to confirm data (should return numbers immediately):  
   - Kafka totals: `kafka_server_brokertopicmetrics_messagesin_total{topic=~"txn1|txn2|txn_fraud"}`  
   - NiFi flowing: `nifi_amount_items_queued{namespace="cfm-streaming"}`  
   - Flink flowing: `flink_taskmanager_job_task_operator_numRecordsInPerSecond{namespace="cld-streaming"}`  
   - Overall cluster: `sum(kube_pod_info{namespace=~"cfm-streaming|cld-streaming"}) by (namespace)`

If any return no data → re-apply the PodMonitor/ServiceMonitor YAMLs from Parts 1-3 and restart Prometheus pod.

### Phase 1: Create the New Dashboard (10 minutes)
1. In Grafana → left menu **Dashboards** → **New** → **New dashboard**.  
2. Title: `End-to-End CSO Fraud Detection Dashboard`  
3. Folder: `Cloudera Streaming Operators` (create it if missing).  
4. Tags: `cso`, `fraud`, `observability`, `nifi`, `kafka`, `flink`.  
5. Time range: Last 30 minutes (default is fine).  
6. Save immediately (name it exactly the same).

### Phase 2: Top Row – Counter Tiles (Stat Panels) – Total Transactions (15 minutes)
Add a new **Row** titled `Fraud Pipeline Totals (Cumulative)`.  
Inside the row, add **3 Stat panels** side-by-side (use **Add panel** → **Stat**).

**Panel 1: Total Transactions 1 (txn1)**  
- Title: `Total Transactions 1 (txn1)`  
- Description: `Cumulative messages ingested into txn1 topic (NiFi → Kafka)`  
- Query (Prometheus data source):  
  ```promql
  sum(kafka_server_brokertopicmetrics_messagesin_total{topic="txn1", namespace="cld-streaming"})
  ```  
- Panel options:  
  - Value: `Calc` → `Last (not null)`  
  - Units: `none` (or `short` if you want commas)  
  - Color mode: `Value` → Thresholds: green > 0  
  - Show name: `Value` only (hide legend)

**Panel 2: Total Transactions 2 (txn2)**  
- Title: `Total Transactions 2 (txn2)`  
- Query:  
  ```promql
  sum(kafka_server_brokertopicmetrics_messagesin_total{topic="txn2", namespace="cld-streaming"})
  ```  
- Same panel options as above.

**Panel 3: Total Fraud (txn_fraud)**  
- Title: `Total Fraud Detected (txn_fraud)`  
- Query:  
  ```promql
  sum(kafka_server_brokertopicmetrics_messagesin_total{topic="txn_fraud", namespace="cld-streaming"})
  ```  
- Same panel options.  
- Optional bonus threshold: red if value > 100 (or whatever makes sense for your lab).

Drag the three panels into one row, resize so they sit nicely at the top.

### Phase 3: Four Flowing Metrics Graphs (25 minutes)
Add a second **Row** titled `Real-Time Flowing Metrics (NiFi → Kafka → Flink)`.  
Add **4 Time Series** panels (or Graph if you prefer classic look).

**Graph 1: NiFi Metrics Flowing**  
- Title: `NiFi Pipeline Throughput (cfm-streaming)`  
- Query A:  
  ```promql
  rate(nifi_amount_items_queued{namespace="cfm-streaming"}[5m]) * 60
  ```  
  (or use `rate(nifi_bytes_sent{namespace="cfm-streaming"}[5m])` if you prefer bytes)  
- Legend: `{{pod}}`  
- Units: `items/min` or `bytes/sec`  
- Line color: orange

**Graph 2: Kafka Metrics Flowing**  
- Title: `Kafka Topic Ingestion Rate (cld-streaming)`  
- Query A:  
  ```promql
  sum(rate(kafka_server_brokertopicmetrics_messagesin_total{topic=~"txn1|txn2|txn_fraud", namespace="cld-streaming"}[5m])) by (topic)
  ```  
- Legend: `{{topic}}`  
- Units: `messages/sec`  
- Line colors: blue (txn1), purple (txn2), red (txn_fraud)

**Graph 3: Flink Metrics Flowing**  
- Title: `Flink/SSB Processing Rate (cld-streaming)`  
- Query A:  
  ```promql
  sum(rate(flink_taskmanager_job_task_operator_numRecordsOut{namespace="cld-streaming"}[5m])) by (job_name)
  ```  
  (adjust `job_name` regex to match your exact SSB fraud job name – check in Prometheus)  
- Legend: `{{job_name}}`  
- Units: `records/sec`  
- Line color: green

**Graph 4: Overall Metrics – cfm-streaming + cld-streaming Namespaces**  
- Title: `Cluster-Wide Observability (Both Namespaces)`  
- Use **two queries** (or one with grouping):  
  Query A (Pods):  
  ```promql
  sum(kube_pod_info{namespace=~"cfm-streaming|cld-streaming"}) by (namespace)
  ```  
  Query B (CPU):  
  ```promql
  sum(rate(container_cpu_usage_seconds_total{namespace=~"cfm-streaming|cld-streaming", container!~"POD"}[5m])) by (namespace)
  ```  
- Legend: `{{namespace}}`  
- Units: `short` / `cores`  
- Override to show two series (or split into two Y-axes if you want).

Resize panels to 6-wide each (12-column grid) so they sit nicely in one row.

### Phase 4: Polish & Best Practices (10 minutes)
- Add **dashboard variables** (top of dashboard):  
  - Variable `namespace` → Query: `label_values(kube_pod_info, namespace) ~ "cfm-streaming|cld-streaming"`  
  - Variable `topic` → Query: `label_values(kafka_server_brokertopicmetrics_messagesin_total, topic) ~ "txn.*|fraud"`  
  Update all queries to use `${namespace}` and `${topic}` where possible.
- Add **annotations** (optional): “NiFi flow started”, “Flink job deployed” so you can mark events.
- Set refresh to **5s** (or 10s).
- Add a **text panel** at the very top with markdown:  
  “**Fraud Detection End-to-End Observability** – NiFi (CFM) → Kafka (CSM) → Flink/SSB (CSA)”
- Theme: Use dark mode + Cloudera orange accents if you want branding.

### Phase 5: Export & Version Control (5 minutes)
1. Dashboard settings → **JSON Model** → Copy.  
2. Save as `cso-fraud-end-to-end-dashboard.json` in your local `ClouderaStreamingOperators` repo (next to the existing `csm-kafka-dashboard.json`).  
3. Commit & push.