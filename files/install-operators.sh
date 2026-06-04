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

kubectl delete secret cfm-operator-license -n cld-streaming --ignore-not-found=true
kubectl create secret generic cfm-operator-license \
  --from-file=license.txt=/home/tunas/license.txt \
  -n cld-streaming

kubectl delete secret cloudera-creds -n cld-streaming --ignore-not-found=true
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

# Install cert manager
helm upgrade --install cert-manager jetstack/cert-manager --version v1.16.3 --namespace cert-manager --create-namespace --set installCRDs=true

# Update Helm Repos
helm repo update

# 4. cfm-streaming Namespace & Secrets
kubectl create namespace cfm-streaming --dry-run=client -o yaml | kubectl apply -f -

kubectl delete secret cfm-operator-license -n cfm-streaming --ignore-not-found=true
kubectl create secret generic cfm-operator-license \
  --from-file=license.txt=/home/tunas/license.txt \
  -n cfm-streaming

kubectl delete secret cloudera-creds -n cfm-streaming --ignore-not-found=true
kubectl create secret docker-registry cloudera-creds \
  --docker-server=container.repository.cloudera.com \
  --docker-username="$CLOUDERA_USER" \
  --docker-password="$CLOUDERA_PASS" \
  -n cfm-streaming

kubectl delete secret nifi-admin-creds -n cfm-streaming --ignore-not-found=true
kubectl create secret generic nifi-admin-creds \
  --from-literal=username="admin" \
  --from-literal=password="$NIFI_ADMIN_PASS" \
  -n cfm-streaming

echo "✅ All namespaces and secrets created successfully!"

# Needed for CSA
kubectl apply -f https://github.com/jetstack/cert-manager/releases/download/v1.8.2/cert-manager.yaml
kubectl wait -n cert-manager --for=condition=Available deployment --all

echo "✅ Cert Manager Installed"

helm upgrade --install strimzi-cluster-operator --namespace cld-streaming --set 'image.imagePullSecrets[0].name=cloudera-creds' --set-file clouderaLicense.fileContent=/home/tunas/license.txt --set watchAnyNamespace=true oci://container.repository.cloudera.com/cloudera-helm/csm-operator/strimzi-kafka-operator --version 1.6.0-b99

helm upgrade --install csa-operator --namespace cld-streaming \
    --version 1.5.0-b275 \
    --set 'flink-kubernetes-operator.imagePullSecrets[0].name=cloudera-creds' \
    --set 'ssb.sse.image.imagePullSecrets[0].name=cloudera-creds' \
    --set 'ssb.sqlRunner.image.imagePullSecrets[0].name=cloudera-creds' \
    --set 'ssb.mve.image.imagePullSecrets[0].name=cloudera-creds' \
    --set 'ssb.database.imagePullSecrets[0].name=cloudera-creds' \
    --set 'ssb.flink.image.imagePullSecrets[0].name=cloudera-creds' \
    --set-file flink-kubernetes-operator.clouderaLicense.fileContent=/home/tunas/license.txt \
    oci://container.repository.cloudera.com/cloudera-helm/csa-operator/csa-operator

helm upgrade --install cfm-operator oci://container.repository.cloudera.com/cloudera-helm/cfm-operator/cfm-operator \
  --namespace cfm-streaming \
  --version 3.0.0-b126 \
  --set installCRDs=true \
  --set image.repository=container.repository.cloudera.com/cloudera/cfm-operator \
  --set image.tag=3.0.0-b126 \
  --set "image.imagePullSecrets[0].name=cloudera-creds" \
  --set "imagePullSecrets={cloudera-creds}" \
  --set "authProxy.image.repository=container.repository.cloudera.com/cloudera_thirdparty/hardened/kube-rbac-proxy" \
  --set "authProxy.image.tag=0.19.0-r3-202503182126" \
  --set licenseSecret=cfm-operator-license

  echo "✅ Operators Installed"