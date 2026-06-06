## How To Install Cloudera Edge Flow Manager Agent Binaries

You have **MiNiFi Java** binaries, **MiNiFi C++ Windows** binaries (`.msi`), **MiNiFi C++ Linux x86_64** binaries, and now **MiNiFi C++ Linux ARM64 (aarch64)** binaries for your Jetson device. EFM is a multi-tenant agent manager; it evaluates the incoming agent heartbeats using a strict coordinate layout: `${agentType}/${osArch}/${agentVersion}`.

**Critical Lessons Applied:**

1. EFM's UI validator rejects hyphens in the `osArch` name. We must use `linux` for x86_64 and `linuxaarch64` for ARM64.
2. EFM's backend validator will throw a `400 BAD_REQUEST` if there is more than exactly *one* archive file in a `binaries` leaf directory. All extensions must be isolated into the `extensions` directory path.

---

### Step 1: Deep Breakdown of Your Local Files to EFM Mappings

| Local File Name | Agent Type | OS Arch | Expected EFM Path | Target Version | Final EFM File Name |
| --- | --- | --- | --- | --- | --- |
| `nifi-minifi-cpp-...-bin-linux.tar.gz` | `cpp` | `linux` | `binaries` | `1.26.02` | `minifi.tar.gz` |
| `nifi-minifi-cpp-...-bin-linux-arm64.tar.gz` | `cpp` | `linuxaarch64` | `binaries` | `1.26.02` | `minifi.tar.gz` |
| `nifi-minifi-cpp-...-extra-extensions-linux.tar.gz` | `cpp` | `linux` | `extensions` | `1.26.02` | `extra-extensions.tar.gz` |
| `nifi-minifi-cpp-...-extra-extensions-linux-arm64.tar.gz` | `cpp` | `linuxaarch64` | `extensions` | `1.26.02` | `extra-extensions.tar.gz` |
| `nifi-minifi-cpp-...-extra-python-components.zip` | `cpp` | `linux` | `extensions` | `1.26.02` | `extra-python-components.zip` |
| `nifi-minifi-cpp-...-x64.msi` | `cpp` | `windows` | `binaries` | `1.26.02` | `minifi.msi` |
| `minifi-2.24.08.0-19-bin.tar.gz` | `java` | `linux` | `binaries` | `2.24.08.0-19` | `minifi.tar.gz` |

---

### Step 2: Build the Full Local Staging Tree

```bash
# 1. Clear out the previous staging attempt
rm -rf ~/efm-binaries/staging

# 2. Generate the directory tree for Core Binaries
mkdir -p ~/efm-binaries/staging/binaries/cpp/linux/1.26.02
mkdir -p ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02
mkdir -p ~/efm-binaries/staging/binaries/cpp/windows/1.26.02
mkdir -p ~/efm-binaries/staging/binaries/java/linux/2.24.08.0-19

# 3. Generate the directory tree for Extensions
mkdir -p ~/efm-binaries/staging/extensions/cpp/linux/1.26.02
mkdir -p ~/efm-binaries/staging/extensions/cpp/linuxaarch64/1.26.02

# 4. Stage C++ Linux (x86_64) files
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-bin-linux.tar.gz ~/efm-binaries/staging/binaries/cpp/linux/1.26.02/minifi.tar.gz
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-extensions-linux.tar.gz ~/efm-binaries/staging/extensions/cpp/linux/1.26.02/extra-extensions.tar.gz
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-python-components.zip ~/efm-binaries/staging/extensions/cpp/linux/1.26.02/extra-python-components.zip

# 5. Stage C++ Linux (ARM64/Jetson) files
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-bin-linux-arm64.tar.gz ~/efm-binaries/staging/binaries/cpp/linuxaarch64/1.26.02/minifi.tar.gz
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-extra-extensions-linux-arm64.tar.gz ~/efm-binaries/staging/extensions/cpp/linuxaarch64/1.26.02/extra-extensions.tar.gz

# 6. Stage C++ Windows files
cp ~/efm-binaries/nifi-minifi-cpp-1.26.02-b30-x64.msi ~/efm-binaries/staging/binaries/cpp/windows/1.26.02/minifi.msi

# 7. Stage Java Linux files
cp ~/efm-binaries/minifi-2.24.08.0-19-bin.tar.gz ~/efm-binaries/staging/binaries/java/linux/2.24.08.0-19/minifi.tar.gz

```

---

### Step 3: Stream via Tar Pipe

```bash
# 1. Secure the active pod identifier
EFM_POD=$(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}')

# 2. WIPE the old deployment targets to guarantee a clean slate
kubectl exec -it $EFM_POD -n cld-streaming -- sh -c "rm -rf /opt/efm/efm-2.3.1.0-2/agent-deployer/binaries /opt/efm/efm-2.3.1.0-2/agent-deployer/extensions"

# 3. Explicitly build the fresh top-level parent targets
kubectl exec -it $EFM_POD -n cld-streaming -- sh -c "mkdir -p /opt/efm/efm-2.3.1.0-2/agent-deployer/binaries /opt/efm/efm-2.3.1.0-2/agent-deployer/extensions"

# 4. Stream the local block
tar -cf - -C ~/efm-binaries/staging/ . | kubectl exec -i $EFM_POD -n cld-streaming -- tar -xf - -C /opt/efm/efm-2.3.1.0-2/agent-deployer/

```

---

### Step 4: The Ultimate Verification Routine

Don't guess if it worked—verify it. Run this command to trace every file sitting inside the EFM deployment structure:

```bash
kubectl exec -it $EFM_POD -n cld-streaming -- find /opt/efm/efm-2.3.1.0-2/agent-deployer/ -type f | grep -E "binaries|extensions" | sort

```

#### Your output must match this exact tree:

```text
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp/linux/1.26.02/minifi.tar.gz
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp/linuxaarch64/1.26.02/minifi.tar.gz
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/cpp/windows/1.26.02/minifi.msi
/opt/efm/efm-2.3.1.0-2/agent-deployer/binaries/java/linux/2.24.08.0-19/minifi.tar.gz
```

---

### Step 5: Force EFM to Re-index the World

Bounce the deployment tracking layout so that the Spring Boot context wakes up and registers the clean, validated configurations:

```bash
kubectl rollout restart deployment/efm -n cld-streaming
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s

```

Go open or refresh your browser tab at `http://localhost:10090/efm/ui` (or your proxy interface address). The UI dropdown will now cleanly display **`v1.26.02 - linux`**, **`v1.26.02 - windows`**, and **`v2.24.08.0-19 - linux`**. Clicking them to generate the scripts will successfully pass both UI and Backend validation.

### Working Edge Flow Manager Deploy Agent CLI Command Samples

java 

```
curl -L \
 -d agentClass=test \
 -d agentIdentifier=e9faec53-6301-4ba1-a9e9-2403674ccdb2 \
 -d agentType=java \
 -d agentVersion=2.24.08.0-19 \
 -d autoConfigureSecurity=false \
 -d baseUrl=http%3A%2F%2F127.0.0.1%3A46663%2Fefm%2Fapi \
 -d hbPeriod=5000 \
 -d osArch=linux \
 -d serviceName=minifi \
 -d serviceUser=minifi \
 -d trustSelfSignedCertificates=false \
 http://127.0.0.1:46663/efm/api/agent-deployer/script | bash -
```

cpp linux

```
curl -L \
 -d agentClass=test \
 -d agentIdentifier=54be1fee-9f21-4328-8b86-3b1c5a822b0b \
 -d agentType=cpp \
 -d agentVersion=1.26.02 \
 -d autoConfigureSecurity=false \
 -d baseUrl=http%3A%2F%2F127.0.0.1%3A46663%2Fefm%2Fapi \
 -d hbPeriod=5000 \
 -d osArch=linux \
 -d serviceName=minifi \
 -d serviceUser=minifi \
 -d trustSelfSignedCertificates=false \
 http://127.0.0.1:46663/efm/api/agent-deployer/script | bash -
```

cpp windows

```bash
Set-ExecutionPolicy Bypass -Scope Process -Force;`
Invoke-WebRequest `
 -Uri http://127.0.0.1:46663/efm/api/agent-deployer/script `
 -Method Post `
 -Body ("agentClass=test" + `
       "&agentIdentifier=a66d299f-e7a3-42ea-84cf-3669009e4596" + `
       "&agentType=cpp" + `
       "&agentVersion=1.26.02" + `
       "&autoConfigureSecurity=false" + `
       "&baseUrl=http%3A%2F%2F127.0.0.1%3A46663%2Fefm%2Fapi" + `
       "&hbPeriod=5000" + `
       "&osArch=windows" + `
       "&serviceName=minifi" + `
       "&serviceUser=minifi" + `
       "&trustSelfSignedCertificates=false") `
 -UseBasicParsing `
 -ContentType "application/x-www-form-urlencoded" `
 | Invoke-Expression
```



kubectl port-forward --address 0.0.0.0 service/efm 10090:10090 -n cld-streaming

tunas@MINI-Gaming-G1:~$ minikube service efm -n cld-streaming
┌───────────────┬──────┬──────────────┬───────────────────────────┐
│   NAMESPACE   │ NAME │ TARGET PORT  │            URL            │
├───────────────┼──────┼──────────────┼───────────────────────────┤
│ cld-streaming │ efm  │ efm-ui/10090 │ http://192.168.49.2:30517 │
│               │      │ metrics/9092 │ http://192.168.49.2:30608 │
└───────────────┴──────┴──────────────┴───────────────────────────┘
🔗  Starting tunnel for service efm.
┌───────────────┬──────┬─────────────┬────────────────────────┐
│   NAMESPACE   │ NAME │ TARGET PORT │          URL           │
├───────────────┼──────┼─────────────┼────────────────────────┤
│ cld-streaming │ efm  │             │ http://127.0.0.1:43431 │
│               │      │             │ http://127.0.0.1:41909 │
└───────────────┴──────┴─────────────┴────────────────────────┘
[cld-streaming efm  http://127.0.0.1:43431
http://127.0.0.1:41909]
❗  Because you are using a Docker driver on linux, the terminal needs to be open to run it.

### PowerShell History

PS C:\Users\tunas> history

  Id CommandLine
  -- -----------
   1 # 1. Allow the port through Windows Firewall
   2 New-NetFirewallRule -DisplayName "EFM-Bridge-46663" -Di...
   3 # 2. Map the traffic from your Windows LAN IP to your W...
   4 # Replace '172.26.201.5' with your WSL Ubuntu IP (that'...
   5 netsh interface portproxy add v4tov4 listenport=46663 l...
   6 ipconfig
   7 cd ..\..\Users\tunas
   8 nano .\.wslconfig
   9 edit .\.wslconfig
  10 wsl --shutdown
  11 New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Pro...
  12 New-NetFirewallRule -DisplayName "Allow EFM Port 10090"...

### Deployment CLI Command Sample (Jetson / ARM64)

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
 http://127.0.0.1:46663/efm/api/agent-deployer/script | bash -

```