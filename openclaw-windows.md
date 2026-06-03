**Setup Plan for OpenClaw on Windows Desktop (WSL2 Ubuntu)**

The goal is a reproducible environment where your **OpenClaw agent** can recreate the full Minikube + Docker + Kubernetes setup (and related tools) via skills/jobs. OpenClaw runs best in WSL2 for Linux compatibility, tool access, and stability. 

### Phase 1: Initial Minikube Env Script

**Create a basic "env recreation" script** for the agent (e.g., `~/recreate-minikube-env.sh`):

```bash
#!/bin/bash
set -e
minikube delete || true
minikube start --driver=docker --container-runtime=docker --gpus=all --mount --mount-string="/usr/lib/wsl:/usr/lib/wsl" --force-systemd=true --extra-config=kubelet.cgroup-driver=systemd --cpus=12 --memory=24000
# Add your deployments, services, etc. here (e.g., kubectl apply -f ...)

kubectl create secret generic hf-token --from-literal=HF_TOKEN="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"

echo "=== Cleaning Up Old Port-Forward Infrastructure ==="
pkill -f "port-forward" || true

echo "=== Deploying vLLM Qwen Server (24k Context Engine) ==="
if [ -f "vllm-qwen.yaml" ]; then
  sed -i 's/imagePullPolicy: Always/imagePullPolicy: IfNotPresent/g' vllm-qwen.yaml
  kubectl apply -f vllm-qwen.yaml
else
  echo "ERROR: vllm-qwen.yaml not found in current directory!"
  exit 1
fi

echo "=== Waiting for vLLM Server to Stabilize ==="
kubectl rollout status deployment/vllm-server --timeout=180s

echo "=== [6/6] Instantiating the Network Bridge ==="
kubectl port-forward deployment/vllm-server 8000:8000 > /dev/null 2>&1 &

echo "=================================================="
echo "🚀 Minikube env recreated & local LLM is online! 🚀"
echo "=================================================="
```
Make executable: `chmod +x ~/recreate-minikube-env.sh`

### Phase 3: Install OpenClaw in WSL2

Recommended quick install (inside Ubuntu):

```bash

curl -fsSL https://openclaw.ai/install.sh | bash

```

### Phase 4:  Setup Telegram for Agent Chat

Summarize download Telegram windows and phone.  Login phone, login windows.  Message @BotFather to create @tunastreet_bot, authorize bot, save token for OpenClaw onboarding.

### Phase 5: Configure OpenClaw for Your Goal

During `openclaw onboard`:



- **Add API keys** for strong LLM (e.g., OpenAI, Anthropic, or local Ollama with CUDA).

- **Install/enable skills** relevant to devops: Shell execution, Docker, Git, Kubernetes (kubectl), file ops, web browsing, etc. OpenClaw has plugin/skill system for these.

- **Create a dedicated Agent** (e.g., "DevOpsClaw") with instructions:  

  "You are a Kubernetes/Minikube expert. To recreate my env, run the script ~/recreate-minikube-env.sh or equivalent kubectl/minikube commands. Always verify with kubectl get all."

- **Connect channels** (Telegram, Discord, etc.) for interaction.

- **Give it workspace access** to your Minikube scripts/configs (bind mounts if Dockerized).

- **Enable sandbox** (Docker-based) cautiously for safe command execution.



Test the agent: Ask it "Recreate my Minikube environment" and provide context.



### Phase 6: OpenClaw Config

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

### Phase 7: Installing Qwen OpenAI Compatible Provider for OpenClaw

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

You will need to wait for several minutes for the pods to be in running state.  Then it will be a bit more wait for Bits and Bites to finish downloading.  Wait for the logs to report the application is running. 

Now you can port forward:

```bash
kubectl port-forward svc/vllm-service 8000:8000 &
```
If your port forward crashes when testing the model,  its not running yet.  Check the pod logs for issues or wait until application is running.

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