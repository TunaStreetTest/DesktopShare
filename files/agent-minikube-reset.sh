#!/bin/bash
set -e
minikube delete || true
minikube start --driver=docker --container-runtime=docker --gpus=all --mount --mount-string="/usr/lib/wsl:/usr/lib/wsl" --force-systemd=true --extra-config=kubelet.cgroup-driver=systemd --cpus=12 --memory=24000
# Add your deployments, services, etc. here (e.g., kubectl apply -f ...)

kubectl create secret generic hf-token --from-literal=HF_TOKEN="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"

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
kubectl rollout status deployment/vllm-server --timeout=180s

echo "=== [6/6] Instantiating the Network Bridge ==="
kubectl port-forward deployment/vllm-server 8000:8000 > /dev/null 2>&1 &

echo "=================================================="
echo "🚀 Minikube env recreated & local LLM is online! 🚀"
echo "=================================================="