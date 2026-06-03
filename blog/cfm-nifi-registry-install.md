Here is the finalized, simple markdown deployment plan for installing the NiFi Registry with CFM Operator using the native LoadBalancer route.

---

## 1. Create the Deployment File

Save the following combined manifest as `nifi-registry.yaml`. This bundles the custom registry resource with a LoadBalancer service mapped to the exact pod signature.

```yaml
apiVersion: cfm.cloudera.com/v1alpha1
kind: NifiRegistry
metadata:
  name: nifi-registry-edge
  namespace: cfm-streaming
spec:
  image:
    repository: container.repository.cloudera.com/cloudera/cfm-nifiregistry-k8s
    tag: 3.0.0-b126-nifi_2.6.0.4.3.4.0-234
  tiniImage:
    repository: container.repository.cloudera.com/cloudera/cfm-tini
    tag: 3.0.0-b126
---
apiVersion: v1
kind: Service
metadata:
  name: nifi-registry-edge-svc
  namespace: cfm-streaming
spec:
  type: LoadBalancer
  ports:
    - name: http
      port: 18080
      targetPort: 18080
      protocol: TCP
  selector:
    statefulset.kubernetes.io/pod-name: nifi-registry-edge-0

```

## 2. Apply the Manifest

Deploy both resources to your cluster:

```bash
kubectl apply -f nifi-registry.yaml

```

## 3. Route the LoadBalancer (Minikube Only)

Because Minikube runs inside an isolated network engine, clear the `<pending>` external IP state by opening a network bridge in a separate, dedicated terminal window:

```bash
minikube tunnel

```

*Keep this terminal window running in the background.*

## 4. Verify External Access

Confirm that the service has successfully received its external interface binding:

```bash
kubectl get svc nifi-registry-edge-svc -n cfm-streaming

```

* **Success Criteria:** The `EXTERNAL-IP` column must now display `127.0.0.1` instead of `<pending>`.

## 5. Access the UI & Initialize the Bucket

1. Open your web browser and navigate directly to:
```text
http://127.0.0.1:18080/nifi-registry/

```