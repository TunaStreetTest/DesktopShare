**Setup Plan for OpenClaw on Windows Desktop (WSL2 Ubuntu)**

The goal is for my first **OpenClaw agent** to recreate the full minikube + vLLM Qwen2.5-3B (24k context) stack on demand — zero-dollar local tokens, full Kubernetes control, Telegram-first interface. Everything runs inside WSL2 Ubuntu on my Windows desktop for maximum stability and native tool access.

**Required Final Status**: The agent can now reliably reset the entire environment via `~/recreate-minikube-env.sh`. 

---

### Phase 1: Initial Minikube Env Recreation Script

**Script location**: `~/recreate-minikube-env.sh`

This is the **single minikube restart script** the OpenClaw agent will call to “reset environment”.

```bash
#!/bin/bash
set -e

echo "=== [1/6] Deleting old Minikube cluster (if exists) ==="
minikube delete || true

echo "=== [2/6] Starting fresh Minikube with GPU + WSL2 mounts ==="
minikube start \
  --driver=docker \
  --container-runtime=docker \
  --gpus=all \
  --mount \
  --mount-string="/usr/lib/wsl:/usr/lib/wsl" \
  --force-systemd=true \
  --extra-config=kubelet.cgroup-driver=systemd \
  --cpus=12 \
  --memory=24000

echo "=== [3/6] Creating Hugging Face token secret ==="
kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN="YOUR_HF_TOKEN_HERE" --dry-run=client -o yaml | kubectl apply -f -

echo "=== [4/6] Cleaning up stale port-forwards ==="
pkill -f "port-forward" || true

echo "=== [5/6] Deploying vLLM Qwen Server (24k Context) ==="
if [ -f "vllm-qwen.yaml" ]; then
  sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' vllm-qwen.yaml
  kubectl apply -f vllm-qwen.yaml
else
  echo "ERROR: vllm-qwen.yaml not found!"
  exit 1
fi

echo "=== [6/6] Waiting for vLLM pod to stabilize (up to 3 minutes) ==="
kubectl rollout status deployment/vllm-server --timeout=180s

echo "=== Starting background port-forward to localhost:8000 ==="
kubectl port-forward deployment/vllm-server 8000:8000 > /dev/null 2>&1 &

echo "=================================================="
echo "✅ Minikube env recreated & local Qwen LLM is online!"
echo "=================================================="
echo "Verify with: curl http://localhost:8000/v1/models"
```

Make it executable once:
```bash
chmod +x ~/recreate-minikube-env.sh
```

**Pro tip from Day 1**: The original 4-6 minute timeout is real. The script now includes better waiting logic and secret handling so the agent can run it safely without manual intervention.

---

### Phase 2: Prerequisites (WSL2 + NVIDIA + Minikube)

Added for context — I have already done most of this in my prev env work.  Your experience may vary here.

```bash
# One-time Windows/WSL2 prep
sudo apt-get update && sudo apt-get install -y build-essential curl git
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install gcc
# Ensure NVIDIA drivers are visible inside WSL2
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.0.0-base-ubuntu22.04 nvidia-smi
```

---

### Phase 3: Quick OpenClaw Install

```bash
curl -fsSL https://openclaw.ai/install.sh | bash
```

Then run:
```bash
openclaw onboard                  # my first time i broke and cancelled
openclaw onboard --reset          # fresh start
openclaw onboard --no-verify      # skip some checks if needed
openclaw gateway start
openclaw tui                      # optional interactive mode
```

---

### Phase 4: Telegram Bot Setup

1. Install Telegram Desktop on Windows + Telegram on your phone.
2. On phone: Message `@BotFather` → `/newbot` → name it `@tunastreet_bot` (or whatever you want).
3. Copy the bot token.
4. Authorize the bot on both devices.
5. During `openclaw onboard` or via config, paste the token into the Telegram section.

**Test command**:
```bash
openclaw pairing approve telegram J7LMQY9F   # replace with your pairing code
openclaw channels status --probe
```

---

### Phase 5: Onboarding & Agent Configuration (Documented from Your Successful Run)

During onboarding you set:
- Primary model → custom provider `http://127.0.0.1:8000` (Qwen/Qwen2.5-3B-Instruct)
- System instructions (see Phase 6)
- Tools profile → `coding` + explicit allow list: `["exec", "read", "write", "edit", "process"]`
- Disable mobile-only skills (camera, sms, contacts, etc.)
- Enable Telegram channel with `requireMention: true`

**Key post-onboarding fixes you applied** (these were the ones that actually worked):
- Multiple `openclaw doctor --fix`
- `openclaw gateway restart` cycles
- Python JSON patches for clean `tools.allow` and `max_tokens: 1024`
- `openclaw exec-policy preset yolo` + `openclaw approvals set` with full security mode
- Manual `~/.openclaw/openclaw.json` edits when CLI failed

---

### Phase 6: Final OpenClaw Config (`~/.openclaw/openclaw.json`)

cat ~/.openclaw/openclaw.json

```bash
{
  "agents": {
    "defaults": {
      "workspace": "/home/tunas/.openclaw/workspace",
      "model": {
        "primary": "custom-127-0-0-1-8000/Qwen/Qwen2.5-3B-Instruct"
      },
      "models": {
        "custom-127-0-0-1-8000/Qwen/Qwen2.5-3B-Instruct": {
          "alias": "qwen"
        }
      }
    }
  },
  "gateway": {
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "590713cb16618e429a251b8f528631d63134c8a4827211b5"
    },
    "port": 18789,
    "bind": "loopback",
    "tailscale": {
      "mode": "off",
      "resetOnExit": false
    },
    "controlUi": {
      "allowInsecureAuth": true
    },
    "nodes": {
      "denyCommands": [
        "camera.snap",
        "camera.clip",
        "screen.record",
        "contacts.add",
        "calendar.add",
        "reminders.add",
        "sms.send",
        "sms.search"
      ]
    }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "tools": {
    "profile": "coding",
     "exec": {
      "host": "auto"
    },
    "web": {
      "search": {
        "provider": "duckduckgo",
        "enabled": true
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "custom-127-0-0-1-8000": {
        "baseUrl": "http://127.0.0.1:8000/v1",
        "api": "openai-completions",
        "apiKey": "none",
        "models": [
          {
            "id": "Qwen/Qwen2.5-3B-Instruct",
            "name": "Qwen/Qwen2.5-3B-Instruct (Custom Provider)",
            "contextWindow": 128000,
            "maxTokens": 8192,
            "input": [
              "text"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "reasoning": false
          }
        ]
      }
    }
  },
  "plugins": {
    "entries": {
      "telegram": {
        "enabled": true
      },
      "duckduckgo": {
        "enabled": true
      }
    }
  },
  "channels": {
    "telegram": {
      "enabled": true,
      "groups": {
        "*": {
          "requireMention": true
        }
      },
      "botToken": "8511465033:AAEWa8Xt10luM9c-b2DVxaA6xozrTEN09oI"
    }
  },
  "wizard": {
    "lastRunAt": "2026-06-02T23:55:37.408Z",
    "lastRunVersion": "2026.5.28",
    "lastRunCommand": "doctor",
    "lastRunMode": "local"
  },
  "meta": {
    "lastTouchedVersion": "2026.5.28",
    "lastTouchedAt": "2026-06-02T23:59:58.652Z"
  },
  "commands": {
    "bash": true,
    "config": true,
    "ownerAllowFrom": [
      "telegram:8541049112"
    ]
  },
  "tools": {
    "elevated": {
      "enabled": true,
      "allowFrom": {
        "telegram": ["8541049112"]
      }
    }
  },
  "skills": {
    "entries": {
      "1password": {
        "enabled": false
      },
      "apple-notes": {
        "enabled": false
      },
      "apple-reminders": {
        "enabled": false
      },
      "bear-notes": {
        "enabled": false
      },
      "blogwatcher": {
        "enabled": false
      },
      "blucli": {
        "enabled": false
      },
      "camsnap": {
        "enabled": false
      },
      "clawhub": {
        "enabled": false
      },
      "coding-agent": {
        "enabled": false
      },
      "discord": {
        "enabled": false
      },
      "eightctl": {
        "enabled": false
      },
      "gemini": {
        "enabled": false
      },
      "gh-issues": {
        "enabled": false
      },
      "gifgrep": {
        "enabled": false
      },
      "github": {
        "enabled": false
      },
      "gog": {
        "enabled": false
      },
      "goplaces": {
        "enabled": false
      },
      "himalaya": {
        "enabled": false
      },
      "imsg": {
        "enabled": false
      },
      "mcporter": {
        "enabled": false
      },
      "model-usage": {
        "enabled": false
      },
      "nano-pdf": {
        "enabled": false
      },
      "obsidian": {
        "enabled": false
      },
      "openai-whisper": {
        "enabled": false
      },
      "openai-whisper-api": {
        "enabled": false
      },
      "openhue": {
        "enabled": false
      },
      "oracle": {
        "enabled": false
      },
      "ordercli": {
        "enabled": false
      },
      "peekaboo": {
        "enabled": false
      },
      "sag": {
        "enabled": false
      },
      "session-logs": {
        "enabled": false
      },
      "sherpa-onnx-tts": {
        "enabled": false
      },
      "slack": {
        "enabled": false
      },
      "songsee": {
        "enabled": false
      },
      "sonoscli": {
        "enabled": false
      },
      "spotify-player": {
        "enabled": false
      },
      "summarize": {
        "enabled": false
      },
      "things-mac": {
        "enabled": false
      },
      "trello": {
        "enabled": false
      },
      "video-frames": {
        "enabled": false
      },
      "voice-call": {
        "enabled": false
      },
      "wacli": {
        "enabled": false
      },
      "xurl": {
        "enabled": false
      }
    }
  }
}
```
**!! the big win here was unlocking command `/bash` ,  also `/exec` is not execute.  Thanks AI we are both learning !!**

**Apply changes**:
```bash
openclaw gateway stop && openclaw gateway start
openclaw doctor --fix # only if you need
```

Check Gateway Status

`openclaw gateway status`

```bash
OpenClaw 2026.5.28 (e932160)
Less clicking, more shipping, fewer "where did that file go" moments.

│
◇
Service: systemd user (enabled)
File logs: /tmp/openclaw/openclaw-2026-06-03.log
Command: /home/tunas/.nvm/versions/node/v24.15.0/bin/node /home/tunas/.nvm/versions/node/v24.15.0/lib/node_modules/openclaw/dist/index.js gateway --port 18789
Service file: ~/.config/systemd/user/openclaw-gateway.service
Service env: OPENCLAW_GATEWAY_PORT=18789

Service config looks out of date or non-standard.
Service config issue: Gateway service PATH includes version managers or package managers; recommend a minimal PATH. (/home/tunas/.nvm/versions/node/v24.15.0/bin)
Service config issue: Gateway service uses Node from a version manager; it can break after upgrades. (/home/tunas/.nvm/versions/node/v24.15.0/bin/node)
Recommendation: run "openclaw doctor" (or "openclaw doctor --repair").
Config (cli): ~/.openclaw/openclaw.json
Config (service): ~/.openclaw/openclaw.json

Gateway: bind=loopback (127.0.0.1), port=18789 (service args)
Probe target: ws://127.0.0.1:18789
Dashboard: http://127.0.0.1:18789/
Probe note: Loopback-only gateway; only local clients can connect.

CLI version: 2026.5.28 (~/.nvm/versions/node/v24.15.0/bin/openclaw)
Gateway version: 2026.5.28

Runtime: running (pid 42359, state active, sub running, last exit 0, reason 0)
Connectivity probe: ok
Capability: connected-no-operator-scope

Listening: 127.0.0.1:18789, [::1]:18789
Troubles: run openclaw status
Troubleshooting: https://docs.openclaw.ai/troubleshooting
```
---

### Phase 7: Installing Qwen OpenAI Compatible Provider for OpenClaw

[ I went through many ai rounds with Qwen/Qwen2.5-3B-Instruct, Qwen/Qwen2.5-5B-Instruct,  and Qwen/Qwen2.5-7B-Instruct-Awq
.  In most cases could barely get the model under 8gb of the GPU.  This made it impossible to start.   In this model 32000 finally gives enough headroom for the application to run. ]

cat vllm-qwen.yaml
```bash
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-server
  template:
    metadata:
      labels:
        app: vllm-server
    spec:
      serviceAccountName: vllm-server
      containers:
      - name: vllm-server
        image: vllm/vllm-openai:latest
        env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: hf-token
              key: HF_TOKEN
        resources:
          limits:
            nvidia.com/gpu: 1
        args:
        - "Qwen/Qwen2.5-3B-Instruct"
        - "--quantization"
        - "bitsandbytes"
        - "--load-format"
        - "bitsandbytes"
        - "--gpu-memory-utilization"
        - "0.75"
        - "--max-model-len"
        - "32000"
        - "--enable-chunked-prefill"
        - "--enforce-eager"
        - "--enable-auto-tool-choice"
        - "--tool-call-parser"
        - "qwen3_coder"
        volumeMounts:
        - name: shm
          mountPath: /dev/shm
      volumes:
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: "2Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-service
  namespace: default
spec:
  selector:
    app: vllm-server
  ports:
  - protocol: TCP
    port: 8000
    targetPort: 8000
  type: ClusterIP  # or NodePort/LoadBalancer if you want external access
```

Apply it

```bash
kubectl apply -f vllm-qwen.yaml
```

You will need to wait for several minutes for the pods to be in running state.  Then it will be a bit more of a wait for Bits and Bytes to finish downloading all of its assets. 

`<font color=green>(EngineCore pid=156) INFO 06-03 15:40:52 [bitsandbytes_loader.py:786] Loading weights with BitsAndBytes quantization. May take a while ...</font>`

Wait for the logs to report the application is running. 

`<font color=green>(APIServer pid=1) INFO:     Application startup complete.</font>`

Now you can port forward:

```bash
kubectl port-forward svc/vllm-service 8000:8000 &
```
If your port forward crashes when testing the model,  it's not running yet.  Check the pod logs for issues (not enough memory, gpu, etc) or wait until application is running and try the port forward again.

### Phase 8: Testing OpenClaw Agent

In telegram send `/status`:

🦞 OpenClaw 2026.5.28 (e932160)
⏱️ Uptime: gateway 6h 21m · system 5d 22h
🧠 Model: custom-127-0-0-1-8000/Qwen/Qwen2.5-3B-Instruct · 🔑 api-key (models.json)
🧮 Tokens: 15k in / 45 out · 💵 Cost: $0.0000
📚 Context: 15k/128k (11%) · 🧹 Compactions: 0
🧵 Session: agent:main:telegram:direct:8541049112 • updated just now
⚙️ Execution: direct · Runtime: OpenClaw Default · Think: off · Fast: off
🪢 Queue: steer (depth 0)


`/bash  kubectl config current-context`

```bash
⚙️ bash: kubectl config current-context
Exit: 0

minikube
```

`/bash git clone https://github.com/cldr-steven-matison/DesktopShare.git`

```bash
⚙️ bash: git clone https://github.com/cldr-steven-matison/DesktopShare.git
Exit: 0

Cloning into 'DesktopShare'...
```

`/bash cd DesktopShare && ls -al`

```bash
⚙️ bash: cd DesktopShare && ls -al
Exit: 0

total 364
drwxrwxr-x  7 tunas tunas  4096 Jun  3 13:06 .
drwxr-x--- 29 tunas tunas  4096 Jun  3 13:06 ..
drwxrwxr-x  8 tunas tunas  4096 Jun  3 13:06 .git
-rw-rw-r--  1 tunas tunas  7676 Jun  3 13:06 C++-processors.md
-rw-rw-r--  1 tunas tunas  6975 Jun  3 13:06 Cloudera DataFlow Iceberg CDC Technical Preview.md
-rw-rw-r--  1 tunas tunas  6454 Jun  3 13:06 How To Install Cloudera Iceberg MCP Server.md
-rw-rw-r--  1 tunas tunas  3663 Jun  3 13:06 README.md
-rw-rw-r--  1 tunas tunas  2828 Jun  3 13:06 ai-sources.md
drwxrwxr-x  2 tunas tunas  4096 Jun  3 13:06 blog
-rw-rw-r--  1 tunas tunas  6513 Jun  3 13:06 cfm-persisted-volume.md
-rw-rw-r--  1 tunas tunas  4327 Jun  3 13:06 cloudera-dataflow-cdc-k8s-cdp-pc-iceberg.md
-rw-rw-r--  1 tunas tunas  2968 Jun  3 13:06 cloudera-dataflow-cdc-k8s.md
drwxrwxr-x  2 tunas tunas  4096 Jun  3 13:06 completed
-rw-rw-r--  1 tunas tunas  3082 Jun  3 13:06 csa-airgap.md
-rw-rw-r--  1 tunas tunas  2875 Jun  3 13:06 csa-persisted-volume.md
-rw-rw-r--  1 tunas tunas 12555 Jun  3 13:06 cso-argocd.md
-rw-rw-r--  1 tunas tunas  6578 Jun  3 13:06 cso-minikube-nifi-api-flow-1.md
-rw-rw-r--  1 tunas tunas  4988 Jun  3 13:06 cso-minikube-nifi-api-flow-2.md
-rw-rw-r--  1 tunas tunas  2346 Jun  3 13:06 efm-nifi-registry-install.md
-rw-rw-r--  1 tunas tunas 11328 Jun  3 13:06 efm-nvidia-jetson-nano.md
drwxrwxr-x  2 tunas tunas  4096 Jun  3 13:06 files
-rw-rw-r--  1 tunas tunas  5693 Jun  3 13:06 flink-minikube-gpu-working-2.md
-rw-rw-r--  1 tunas tunas  9829 Jun  3 13:06 flink-minikube-gpu-working.md
-rw-rw-r--  1 tunas tunas  6523 Jun  3 13:06 grok-nifi-kafka-flink-kubernetes-2.md
-rw-rw-r--  1 tunas tunas  6923 Jun  3 13:06 grok-nifi-kafka-flink-kubernetes-3.md
-rw-rw-r--  1 tunas tunas  3843 Jun  3 13:06 grok-nifi-kafka-flink-kubernetes.md
drwxrwxr-x  2 tunas tunas  4096 Jun  3 13:06 history
-rw-rw-r--  1 tunas tunas  4818 Jun  3 13:06 nifi-as-an-api.md
-rw-rw-r--  1 tunas tunas  6421 Jun  3 13:06 nifi-music-alts.md
-rw-rw-r--  1 tunas tunas  4398 Jun  3 13:06 nifi-music-minifi-tuning.md
-rw-rw-r--  1 tunas tunas  6708 Jun  3 13:06 nifi-music-sonification.md
-rw-rw-r--  1 tunas tunas 22939 Jun  3 13:06 nifi-music.md
-rw-rw-r--  1 tunas tunas  4566 Jun  3 13:06 nipyapi.md
-rw-rw-r--  1 tunas tunas 21244 Jun  3 13:06 openclaw-windows-agent.md
-rw-rw-r--  1 tunas tunas  5472 Jun  3 13:06 plan.md
-rw-rw-r--  1 tunas tunas  9137 Jun  3 13:06 rag-app-plan.md
-rw-rw-r--  1 tunas tunas  9450 Jun  3 13:06 sample-opensearch-proc.md
-rw-rw-r--  1 tunas tunas  6448 Jun  3 13:06 spark-versus-cso-1.md
-rw-rw-r--  1 tunas tunas 15059 Jun  3 13:06 spark2_to_spark3-notebookLM-2.md
-rw-rw-r--  1 tunas tunas  9091 Jun  3 13:06 spark2_to_spark3-notebookLM.md
-rw-rw-r--  1 tunas tunas 10216 Jun  3 13:06 spark2_to_spark3.md
-rw-rw-r--  1 tunas tunas  6806 Jun  3 13:06 top10-k8s-gemini-2026.md
-rw-rw-r--  1 tunas tunas  3860 Jun  3 13:06 top10-k8s-grok-2026.md
-rw-rw-r--  1 tunas tunas  4646 Jun  3 13:06 zeppelin.md
```
---

### Further Integration Ideas for Agent Skills

- Github Repo Automation
- Automate update of test user github.io page.
- X/Grok Posting
- Automate posting on X every time repo content is updated.

---

### Appendix: Day 1 Terminal History Summary (Cleaned & Organized)

Here is every **unique** command you ran, deduplicated, grouped, and with context. This is the “what actually worked” reference.

```bash
# 1. vLLM / Kubernetes deployment & debugging
nano vllm-qwen.yaml
kubectl apply -f vllm-qwen.yaml
kubectl delete -f vllm-qwen.yaml
kubectl get pod -l app=vllm-server -o wide
kubectl logs deployment/vllm-server --tail=50 --follow
kubectl describe pod -l app=vllm-server
kubectl port-forward deployment/vllm-server 8000:8000
curl http://localhost:8000/v1/models
curl -i http://localhost:8000/health

# 2. Minikube environment recreation
~/recreate-minikube-env.sh
cat recreate-minikube-env.sh
kubectl get pods -l app=vllm-server
minikube ssh "docker images | grep vllm"

# 3. OpenClaw configuration & fixes
openclaw onboard --reset
openclaw onboard --no-verify
openclaw gateway start
openclaw tui
openclaw config set commands.config true
openclaw config set agents.main.tools.allow '["exec", "read", "write", "edit", "process"]' --strict-json
openclaw doctor --fix
openclaw gateway restart
openclaw config validate
openclaw exec-policy preset yolo
openclaw exec-policy set --mode full --ask-off
openclaw approvals set --stdin '{ "version": 1, "defaults": { "security": "full", "ask": "off", "askFallback": "full" } }'
openclaw config patch '{"tools": {"profile": "full", "exec": {"security": "full", "ask": "off"}}}'

# 4. Python JSON patching (most reliable method)
# (the two python3 -c blocks you used to force tools + max_tokens)

# 5. Misc troubleshooting
openclaw skills list --verbose
openclaw channels status --probe
openclaw pairing approve telegram J7LMQY9F
openclaw logs --follow
pkill -f "port-forward"
nvidia-smi
kubectl create secret generic hf-token --from-literal=HF_TOKEN="..."
kubectl create serviceaccount vllm-server
kubectl create clusterrolebinding vllm-server-admin --clusterrole=cluster-admin --serviceaccount=default:vllm-server
```
---

### Appendix: Basic OpenClaw Agent Commands

`/status`

```bash
🦞 OpenClaw 2026.5.28 (e932160)
⏱️ Uptime: gateway 10h 19m · system 6d 2h
🧠 Model: custom-127-0-0-1-8000/Qwen/Qwen2.5-3B-Instruct · 🔑 api-key (models.json)
🧮 Tokens: 15k in / 54 out · 💵 Cost: $0.0000
📚 Context: 15k/128k (12%) · 🧹 Compactions: 0
🧵 Session: agent:main:telegram:direct:8541049112 • updated just now
⚙️ Execution: direct · Runtime: OpenClaw Default · Think: off · Fast: off
🪢 Queue: steer (depth 0)
```

`/tools compact`

```bash
Available tools

Profile: coding

Built-in tools
cron, edit, exec, process, read, sessions_history, sessions_send, session_status, sessions_list, sessions_spawn, subagents, update_plan, web_fetch, web_search, write, sessions_yield

Connected tools
memory_get (memory-core), memory_search (memory-core)

Use /tools verbose for descriptions.
```


`/commands`

```bash
ℹ️ Commands (1/8)

Session
  /session - Manage session-level settings (for example /session idle).
  /stop - Stop the current run.
  /reset - Reset the current session.
  /new - Start a new session.
  /compact - Compact the session context.

Options
  /usage - Usage footer or cost summary.
  /think (/thinking, /t) - Set thinking level.
  /verbose (/v) - Toggle verbose mode.

ℹ️ Commands (2/8)

Options
  /trace - Toggle plugin trace lines.
  /fast - Toggle fast mode.
  /reasoning (/reason) - Toggle reasoning visibility.
  /elevated (/elev) - Toggle elevated mode.
  /exec - Set exec defaults for this session.
  /model - Show or set the model.
  /models - List model providers/models.
  /queue - Adjust queue settings.

ℹ️ Commands (3/8)

Status
  /help - Show available commands.
  /commands - List all slash commands.
  /tools - List available runtime tools.
  /status - Show current status.
  /diagnostics - Explain Gateway diagnostics and Codex feedback upload options.
  /tasks - List background tasks for this session.
  /context - Explain how context is built and used.
  /export-session (/export) - Export current session to HTML file with full system prompt.

ℹ️ Commands (4/8)

Status
  /export-trajectory (/trajectory) - Export a JSONL trajectory bundle for the active session.
  /whoami (/id) - Show your sender id.

Management
  /crestodian [text] - Run the Crestodian setup and repair helper.
  /allowlist [text] - List/add/remove allowlist entries.
  /approve - Approve or deny exec requests.
  /subagents - Inspect subagent runs for this session.
  /acp - Manage ACP sessions and runtime options.
  /focus - Bind this thread (Discord) or topic/conversation (Telegram) to a session target.

ℹ️ Commands (5/8)

Management
  /unfocus - Remove the current thread (Discord) or topic/conversation (Telegram) binding.
  /agents - List thread-bound agents for this session.
  /steer (/tell) - Send guidance to the active run in this session.
  /config - Show or set config values.
  /activation - Set group activation mode.
  /send - Set send policy.

Media
  /tts - Control text-to-speech (TTS).

Tools
  /skill - Run a skill by name.

ℹ️ Commands (6/8)

Tools
  /btw (/side) - Ask a side question without changing future session context.
  /restart - Restart OpenClaw.
  /bash [text] - Run host shell commands (host-only).
  /canvas - Present HTML on connected OpenClaw node canvases, navigate/eval/snapshot, and debug canvas host URL…
  /diagram_maker - Create SVG/HTML or Excalidraw diagrams for concepts, architecture, flows, and whiteboards.
  /healthcheck - Audit/harden OpenClaw hosts: SSH, firewall, updates, exposure, backups, disk encryption, gateway se…
  /meme_maker - Search meme templates, suggest formats, and generate local or hosted image memes.
  /node_connect - Diagnose OpenClaw Android, iOS, or macOS node pairing, QR/setup code, route, auth, and connection f…

ℹ️ Commands (7/8)

Tools
  /node_inspect_debugger - Debug Node.js with node inspect, --inspect, breakpoints, CDP, heap, and CPU profiles.
  /notion - Notion CLI/API for pages, Markdown content, data sources, files, comments, search, Workers, and raw…
  /python_debugpy - Debug Python with pdb, breakpoint(), post-mortem inspection, and debugpy remote attach.
  /skill_creator - Create, edit, audit, tidy, validate, or restructure AgentSkills and SKILL.md files.
  /spike - Run throwaway prototypes to validate feasibility, compare approaches, and report a verdict.
  /taskflow - Coordinate multi-step detached tasks as one durable TaskFlow job with owner context, state, waits, …
  /taskflow_inbox_triage - Example TaskFlow pattern for inbox triage, intent routing, waiting on replies, and later summaries.
  /tmux - Control tmux sessions/panes for interactive CLIs: list, capture output, send keys, paste text, moni…

ℹ️ Commands (8/8)

Tools
  /weather - Current weather and forecasts with wttr.in via curl for locations, rain, temperature, travel planni…

Docks
  /dock_telegram (/dock-telegram) - Switch to telegram for replies.

Plugins
  /pair (device-pair) - Generate setup codes and approve device pairing requests.
  /dreaming (memory-core) - Enable or disable memory dreaming.
  /phone (phone-control) - Arm/disarm high-risk phone node commands (camera/screen/writes).
  /voice (talk-voice) - List/set Talk provider voices (affects iOS Talk playback).
```