**Setup Plan for OpenClaw on Windows Desktop (WSL2 Ubuntu)**

The goal is for my first **OpenClaw agent** to recreate the full minikube + vLLM Qwen2.5-3B (24k context) stack on demand — zero-dollar local tokens, full Kubernetes control, Telegram-first interface. Everything runs inside WSL2 Ubuntu on my Windows desktop for maximum stability and native tool access.

**Status**: Core stack is working. The agent can now reliably reset the entire environment via `~/recreate-minikube-env.sh`.

---

### Phase 1: Initial Minikube Env Recreation Script

**Script location**: `~/recreate-minikube-env.sh`

This is the **single source of truth** the OpenClaw agent will call whenever it sees a broken cluster or you say “reset environment”.

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

(Added for completeness — you already did most of this)

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
    "config": true,
    "ownerAllowFrom": [
      "telegram:8541049112"
    ]
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

**Apply changes**:
```bash
openclaw gateway stop && openclaw gateway start
openclaw doctor --fix
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

You will need to wait for several minutes for the pods to be in running state.  Then it will be a bit more of a wait for Bits and Bytes to finish downloading all of its assets.  Wait for the logs to report the application is running. 

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

[ At this point the bot can answer, albeit quite naively, or with wrong answer, or ai slop trying to just respond (3B model - can test 5B now too).  I was not able to get any tools to work in terms of EXEC the actual script.   When i did things like tell it to exec a string echo,  it seems to mimic that it did but did it?   If i told it to EXEC the script I am not even sure it could ever see it.   When i suggested it to ls /home/tunas/  it shows empty dir.  In next sessions need to better understand openclaw permissions and abilities including skills.   Additionally need to think in terms of disconnected process so have agent do "process" where process has and is authed to exec a job/script ]

Further Integration Ideas for Agent Skills


Github Repo Automation
  automate update of test user github.io page.
X/Grok Posting
  automate posting on X every time repo content is updated.



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
kubectl create secret generic hf-token-secret --from-literal=HF_TOKEN="..."
kubectl create serviceaccount vllm-server
kubectl create clusterrolebinding vllm-server-admin --clusterrole=cluster-admin --serviceaccount=default:vllm-server
```

---
