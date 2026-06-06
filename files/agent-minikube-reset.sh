#!/bin/bash

# Exit immediately if any command fails
set -e

# 1. Sanity Check: Ensure the environment variables actually exist before running
if [ -z "$HK_TOKEN" ] || [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "❌ Error: Required environment variables are not set."
    echo "Please ensure HK_TOKEN, TOKEN, CHAT_ID are defined."
    exit 1
fi

echo "🚀 Starting MiniKube Agent..."


minikube delete || true
minikube start --driver=docker --container-runtime=docker --gpus=all --mount --mount-string="/usr/lib/wsl:/usr/lib/wsl" --force-systemd=true --extra-config=kubelet.cgroup-driver=systemd --cpus=12 --memory=24000

minikube addons enable ingress
minikube addons enable metrics-server

kubectl create secret generic hf-token --from-literal=HF_TOKEN="$HK_TOKEN"

echo "=== Provisioning vLLM Service Account ==="
kubectl create serviceaccount vllm-server --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding vllm-server-admin --clusterrole=cluster-admin --serviceaccount=default:vllm-server --dry-run=client -o yaml | kubectl apply -f -

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
kubectl rollout status deployment/vllm-server --timeout=6m

echo "=== [6/6] Instantiating the Network Bridge ==="
kubectl port-forward deployment/vllm-server 8000:8000 > /dev/null 2>&1 &

echo "=================================================="
echo "🚀 Minikube env recreated & local LLM is online! 🚀"
echo "=================================================="

if [ $? -eq 0 ]; then
    FINAL_MSG="✅ CSO Deployment completed successfully!"
else
    FINAL_MSG="❌ CSO Deployment failed! Check deploy.log for details."
fi

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
     -d "chat_id=$CHAT_ID" \
     -d "text=${FINAL_MSG}" > /dev/null