## External Networking with Kubernetes**

### Scenario
Your full Cloudera Streaming Operators (CSO) + EFM stack is running on Minikube on your Windows desktop. Everything works great locally via `minikube tunnel` + `http://127.0.0.1:10090/efm/ui` (and similar for NiFi, Kafka, vLLM-server, Prometheus, etc.).

Now the NVIDIA Jetson Orin Nano is joining the same home LAN. The MiNiFi C++ EFM agent running on the Jetson (or inside a Docker container with NVIDIA runtime) needs to:
- Register with EFM (C2 heartbeats, flow + asset downloads)
- Communicate with NiFi (if using NiFi-based flows), Kafka brokers, and the vLLM-server (for any edge-to-cloud inference handoff or hybrid flows)
- Send metrics back to the Prometheus instance in the CSO stack

You also want any other home-network device (laptop, another Jetson, phone on Wi-Fi, etc.) to reach the important ports without SSH tunnels or VPNs.

Minikube’s Docker driver (which you’re using) isolates the cluster networking, so the default LoadBalancer services + `minikube tunnel` only bind to `127.0.0.1` on the Windows host. We need a clean, repeatable way to open the necessary ports to the entire home LAN.

### Solution Summary and Plan of Attack
**Summary:** Keep your existing LoadBalancer services (no YAML changes required for most things). Run `minikube tunnel` on the Windows desktop (it handles LoadBalancer port mapping). Then use Windows built-in `netsh interface portproxy` to forward those ports from your Windows LAN IP to `127.0.0.1`. Add targeted Windows Firewall rules. This is the simplest, least-invasive method for a Windows + Docker-driver Minikube home lab and works perfectly for EFM agents, NiFi, Kafka bootstrap, vLLM, etc.

**Plan of Attack:**
1. Identify the exact services/ports you care about (EFM UI/API, Kafka, vLLM, etc.).
2. Get your stable Windows LAN IP.
3. Start the tunnel and create port-proxy rules (one-time scriptable).
4. Open Windows Firewall for the home network.
5. Update the EFM agent deployment command on the Jetson to use the external URL.
6. Test end-to-end from the Jetson (and optionally document the same pattern for NiFi/Kafka/vLLM in your flows).
7. (Optional later) Migrate high-traffic services to Ingress + a single proxy port for cleaner hostnames.

This keeps everything repeatable, matches the style of the rest of the guide, and requires zero changes to your existing EFM/CSO YAMLs.

### Step-by-Step Implementation

#### 1. Get your Windows desktop LAN IP (stable address)
On the Windows desktop (Command Prompt or PowerShell):

```cmd
ipconfig
```

Look for **IPv4 Address** under your active adapter (Wi-Fi or Ethernet). Example: `192.168.1.42`.  
Call this `<WINDOWS_LAN_IP>` for the rest of the guide.  
(Pro tip: If your router supports DHCP reservations, reserve this IP for the desktop so it never changes.)

#### 2. Identify the ports you need to expose
Run these to see your current LoadBalancer services:

```bash
kubectl get svc -n cld-streaming --field-selector type=LoadBalancer
```

Typical ones you’ll want:
- `efm` → ports 10090 (UI/API) and 9092 (metrics)
- NiFi service (whatever name you have in CSO) → usually 8443 or 8080
- Kafka bootstrap (CSM) → 9092 or 9094 (check your Kafka CR)
- vLLM-server → usually 8000
- (Optional) Grafana, Prometheus, etc.

Note the **port** (not nodePort) for each.

#### 3. Create the port-proxy rules on Windows
Open **Command Prompt as Administrator** on the Windows desktop and run these (replace `<WINDOWS_LAN_IP>` and ports as needed). Do this once per port you care about.

```cmd
:: EFM UI + API (10090)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=10090 connectaddress=127.0.0.1 connectport=10090

:: EFM metrics (9092)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=9092 connectaddress=127.0.0.1 connectport=9092

:: Example for vLLM (adjust port)
netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=8000 connectaddress=127.0.0.1 connectport=8000

:: Add more as needed (Kafka, NiFi, etc.)
```

**To list all current proxies:**
```cmd
netsh interface portproxy show all
```

**To delete a rule later:**
```cmd
netsh interface portproxy delete v4tov4 listenport=10090
```

#### 4. Start the Minikube tunnel (must stay running)
On the Windows desktop (in a dedicated terminal/PowerShell):

```bash
minikube tunnel
```

Leave this running (it can run in the background). It handles all LoadBalancer services.

#### 5. Open Windows Firewall for the home network
1. Open **Windows Defender Firewall → Advanced Settings**.
2. **Inbound Rules → New Rule**.
3. **Port → TCP** → Specific local ports: `10090,9092,8000` (add commas for each port you proxied).
4. **Allow the connection**.
5. **Domain + Private** (uncheck Public unless you really want it).
6. Name it something clear: `Minikube EFM + vLLM - Home LAN`.
7. **Scope** (optional but recommended): Under “Which remote IP addresses...” choose “These IP addresses” and add your home subnet (e.g., `192.168.1.0/24`).

Repeat or create one rule that covers all the ports you proxied.

#### 6. Deploy/Update the MiNiFi C++ EFM agent on the Jetson
On the Jetson (or in the Docker run command), use the **external** baseUrl instead of localhost:

```bash
curl -L \
  -d agentClass=test \
  -d agentIdentifier=b2c63cf5-de86-4b62-8d17-cad369af68ad \
  -d agentType=cpp \
  -d agentVersion=1.26.02 \
  -d autoConfigureSecurity=false \
  -d baseUrl=http%3A%2F%2F<WINDOWS_LAN_IP>%3A10090%2Fefm%2Fapi \
  -d hbPeriod=5000 \
  -d osArch=linux \
  -d serviceName=minifi \
  -d serviceUser=root \
  -d trustSelfSignedCertificates=false \
  http://<WINDOWS_LAN_IP>:10090/efm/api/agent-deployer/script | bash -
```

(If using the pod YAML example from earlier, update the `baseUrl` inside the `args` the same way.)

#### 7. Update your NiFi flows / EFM assets / processor configs
Anywhere a processor or flow needs to talk to Kafka, NiFi Registry, vLLM, etc., replace internal service names with:
- `http://<WINDOWS_LAN_IP>:<port>` (or `https://` if you add TLS later)
- For Kafka: use `<WINDOWS_LAN_IP>:9092` (or whatever external listener port you exposed) as the bootstrap server.

#### 8. Verify everything
From the Jetson:
```bash
# Basic connectivity
ping <WINDOWS_LAN_IP>
curl -I http://<WINDOWS_LAN_IP>:10090/efm/ui
curl -I http://<WINDOWS_LAN_IP>:8000  # vLLM health check example
```

Watch the EFM dashboard — your Jetson agent should appear in the class and start heartbeating.  
Check the agent logs on Jetson for successful flow/asset sync and any outbound connections to Kafka/vLLM.

#### Gotchas & Tips
- `minikube tunnel` **must** stay running on the Windows desktop (use a startup script or Task Scheduler if you want it automatic).
- If you restart Minikube or the EFM pod, the tunnel will re-map the ports automatically.
- Portproxy rules survive reboots, but you may want a small PowerShell script to re-apply them.
- For production-grade later: Deploy the official NGINX Ingress Controller in Minikube, expose **one** LoadBalancer port (e.g. 80/443), and use host-based routing. Much cleaner for many services.
- Security: This is fine for a trusted home LAN. In a real edge deployment you would add mTLS between agents and EFM, or use a VPN/WireGuard tunnel.