#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- 1. VALIDATE ENVIRONMENT VARIABLES ---
if [ -z "$CLOUDERA_USER" ] || [ -z "$CLOUDERA_PASS" ] || [ -z "$NIFI_ADMIN_PASS" ]; then
    echo "❌ Error: Required environment variables are not set."
    echo "Please ensure CLOUDERA_USER, CLOUDERA_PASS, and NIFI_ADMIN_PASS are defined."
    exit 1
fi

# --- 2. INITIALIZE KUBERNETES NAMESPACES ---
echo "🚀 Starting Kubernetes resource creation..."
# Ensure target namespaces exist silently
kubectl create namespace cld-streaming --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
kubectl create namespace cfm-streaming --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1

# --- 3. CONFIGURING CLUSTER SECRETS ---
echo "🔑 Provisioning Core Infrastructure Secrets..."

# Target: cld-streaming Namespace
kubectl delete secret cfm-operator-license -n cld-streaming --ignore-not-found=true >/dev/null 2>&1
kubectl create secret generic cfm-operator-license --from-file=license.txt=/home/tunas/license.txt -n cld-streaming >/dev/null 2>&1

kubectl delete secret cloudera-creds -n cld-streaming --ignore-not-found=true >/dev/null 2>&1
kubectl create secret generic cloudera-creds \
  --from-literal=username="$CLOUDERA_USER" \
  --from-literal=password="$CLOUDERA_PASS" \
  -n cld-streaming >/dev/null 2>&1

# Target: cfm-streaming Namespace
kubectl delete secret cfm-operator-license -n cfm-streaming --ignore-not-found=true >/dev/null 2>&1
kubectl create secret generic cfm-operator-license --from-file=license.txt=/home/tunas/license.txt -n cfm-streaming >/dev/null 2>&1

kubectl delete secret cloudera-creds -n cfm-streaming --ignore-not-found=true >/dev/null 2>&1
kubectl create secret generic cloudera-creds \
  --from-literal=username="$CLOUDERA_USER" \
  --from-literal=password="$CLOUDERA_PASS" \
  -n cfm-streaming >/dev/null 2>&1

kubectl delete secret nifi-admin-creds -n cfm-streaming --ignore-not-found=true >/dev/null 2>&1
kubectl create secret generic nifi-admin-creds \
  --from-literal=username="admin" \
  --from-literal=password="$NIFI_ADMIN_PASS" \
  -n cfm-streaming >/dev/null 2>&1

echo "✅ All namespaces and secrets provisioned successfully."

# --- 4. REGISTRY AUTHENTICATION ---
echo "🔑 Authenticating with Cloudera Helm Registry..."
helm registry login container.repository.cloudera.com \
  -u "$CLOUDERA_USER" \
  -p "$CLOUDERA_PASS" >/dev/null 2>&1

# --- 5. DEPLOY CERT-MANAGER PREREQUISITE ---
echo "⏳ Installing Cert-Manager via Helm (v1.16.3)..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.3 \
  --set installCRDs=true \
  --atomic \
  -q >/dev/null 2>&1

echo "⏳ Waiting for Cert-Manager readiness components..."
kubectl wait -n cert-manager --for=condition=Available deployment --all --timeout=120s >/dev/null 2>&1
echo "✅ Cert-Manager is live and active."

# --- 6. UPDATE HELM REPOSITORIES ---
echo "🔄 Refreshing tracking index for Chart Repositories..."
helm repo update >/dev/null 2>&1

# --- 7. DEPLOY CLOUDERA STREAMING OPERATORS ---
echo "⏳ Initializing Cloudera Streaming Operators Orchestration..."

# [1/3] CSM - Strimzi Kafka Operator
helm upgrade --install strimzi-cluster-operator cloudera/strimzi-kafka-operator \
  --namespace cld-streaming \
  --atomic \
  -q >/dev/null 2>&1
echo "📦 [1/3] CSM (Strimzi Kafka Operator) Deployed successfully."

# [2/3] CSA - Cloudera Streaming Analytics (Flink) Operator
helm upgrade --install csa-operator cloudera/csa-operator \
  --namespace cld-streaming \
  --atomic \
  -q >/dev/null 2>&1
echo "📦 [2/3] CSA (Flink/SSB Operator) Deployed successfully."

# [3/3] CFM - Cloudera Flow Management (NiFi) Operator
helm upgrade --install cfm-operator cloudera/cfm-operator \
  --namespace cfm-streaming \
  --atomic \
  -q >/dev/null 2>&1
echo "📦 [3/3] CFM (NiFi Operator) Deployed successfully."

# --- 8. SUCCESS SUMMARY ---
echo "🎉 ALL CLOUDERA OPERATORS (CFM, CSM, CSA) SUCCESSFULLY UPGRADED & VERIFIED!"