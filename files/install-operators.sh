#!/bin/bash

# Exit immediately if any command fails
set -e

# 1. Sanity Check: Ensure the environment variables actually exist before running
if [ -z "$CLOUDERA_USER" ] || [ -z "$CLOUDERA_PASS" ] || [ -z "$NIFI_ADMIN_PASS" ]; then
    echo "❌ Error: Required environment variables are not set."
    echo "Please ensure CLOUDERA_USER, CLOUDERA_PASS, and NIFI_ADMIN_PASS are defined."
    exit 1
fi

echo "🚀 Starting Kubernetes resource creation..."

# 2. cld-streaming Namespace & Secrets
kubectl create namespace cld-streaming --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cfm-operator-license \
  --from-file=license.txt=/home/tunas/license.txt \
  -n cld-streaming

kubectl create secret docker-registry cloudera-creds \
  --docker-server=container.repository.cloudera.com \
  --docker-username="$CLOUDERA_USER" \
  --docker-password="$CLOUDERA_PASS" \
  -n cld-streaming

# 3. Cloudera Helm Registry
echo "🔑 Logging into Cloudera Helm Registry..."

# Secure way: Piping the environment variable into helm registry login
echo "$CLOUDERA_PASS" | helm registry login container.repository.cloudera.com \
  --username "$CLOUDERA_USER" \
  --password-stdin

# Alternative way (if you don't want to use stdin, though stdin is preferred):
# helm registry login container.repository.cloudera.com --username "$CLOUDERA_USER" --password "$CLOUDERA_PASS"

# 4. cfm-streaming Namespace & Secrets
kubectl create namespace cfm-streaming --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic cfm-operator-license \
  --from-file=license.txt=/home/tunas/license.txt \
  -n cfm-streaming

kubectl create secret docker-registry cloudera-creds \
  --docker-server=container.repository.cloudera.com \
  --docker-username="$CLOUDERA_USER" \
  --docker-password="$CLOUDERA_PASS" \
  -n cfm-streaming

kubectl create secret generic nifi-admin-creds \
  --from-literal=username="admin" \
  --from-literal=password="$NIFI_ADMIN_PASS" \
  -n cfm-streaming

echo "✅ All namespaces and secrets created successfully!"