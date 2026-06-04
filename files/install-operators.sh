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

echo "⏳ Installing Cert-Manager via Helm..."
# 1. Install cert-manager and its matching CRDs cleanly
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.3 \
  --set installCRDs=true

# 2. Wait for the Helm deployment to actually be ready before moving on
echo "⏳ Waiting for Cert-Manager to be ready..."
kubectl wait -n cert-manager --for=condition=Available deployment --all --timeout=120s

echo "✅ Cert-Manager Installed successfully!"

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



helm upgrade --install strimzi-cluster-operator --namespace cld-streaming --set 'image.imagePullSecrets[0].name=cloudera-creds' --set-file clouderaLicense.fileContent=/home/tunas/license.txt --set watchAnyNamespace=true oci://container.repository.cloudera.com/cloudera-helm/csm-operator/strimzi-kafka-operator --version 1.6.0-b99

# this one requires vpn
#  Warning  Failed     27s (x5 over 3m34s)  kubelet            spec.containers{postgresql}: Failed to pull image "docker-private.infra.cloudera.com/cloudera_thirdparty/hardened/postgres:18.1-r0-openshift-202601250614": Error response from daemon: Get "https://docker-private.infra.cloudera.com/v2/": dial tcp: lookup docker-private.infra.cloudera.com on 192.168.65.254:53: no such host
#  Warning  Failed     27s (x5 over 3m34s)  kubelet            spec.containers{postgresql}: Error: ErrImagePull
#  Normal   BackOff    1s (x13 over 3m34s)  kubelet            spec.containers{postgresql}: Back-off pulling image "docker-private.infra.cloudera.com/cloudera_thirdparty/hardened/postgres:18.1-r0-openshift-202601250614"
#  Warning  Failed     1s (x13 over 3m34s)  kubelet            spec.containers{postgresql}: Error: ImagePullBackOff
#helm upgrade --install csa-operator --namespace cld-streaming \
#    --version 1.5.0-b275 \
#    --set 'flink-kubernetes-operator.imagePullSecrets[0].name=cloudera-creds' \
#    --set 'ssb.sse.image.imagePullSecrets[0].name=cloudera-creds' \
#    --set 'ssb.sqlRunner.image.imagePullSecrets[0].name=cloudera-creds' \
#    --set 'ssb.mve.image.imagePullSecrets[0].name=cloudera-creds' \
#    --set 'ssb.database.imagePullSecrets[0].name=cloudera-creds' \
#    --set 'ssb.flink.image.imagePullSecrets[0].name=cloudera-creds' \
#    --set-file flink-kubernetes-operator.clouderaLicense.fileContent=/home/tunas/license.txt \

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

TOKEN="8511465033:AAEWa8Xt10luM9c-b2DVxaA6xozrTEN09oI"
CHAT_ID="8541049112"

if [ $? -eq 0 ]; then
    FINAL_MSG="✅ CSO Deployment completed successfully!"
else
    FINAL_MSG="❌ CSO Deployment failed! Check deploy.log for details."
fi

curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
     -d "chat_id=${CHAT_ID}" \
     -d "text=${FINAL_MSG}" > /dev/null