To get the Cloudera Registry (`container.repo.cloudera.com`) working on a new machine, you need to address how Docker and Kubernetes authenticate with Cloudera's private repository.

When moving to a new machine, the most common failure point is that your host machine has the credentials, but the underlying Kubernetes node/Minikube daemon does not.

Here are the two ways we handle this, depending on your setup on the new machine:

### Method 1: The Local Build Bypass (Our Verified Minikube Strategy)

If you are running Minikube on the new machine and building your image locally, you cannot just run `docker login` on your host terminal. You must inject the authentication token **directly into Minikube’s internal context** before building.

Run these commands in order on the new machine:

```bash
# 1. Point your terminal context to the Docker daemon INSIDE Minikube
eval $(minikube docker-env)

# 2. Log into the private Cloudera registry inside that context
docker login container.repo.cloudera.com

# 3. Build the image locally on the node so Kubernetes doesn't pull from outbound
docker build --no-cache --platform linux/amd64 -t minifi-test:latest .

```

---

### Method 2: The Native Kubernetes Way (`imagePullSecrets`)

If the new machine is pulling images directly from Cloudera's registry at runtime (instead of utilizing a local Docker build step), Kubernetes requires a secret to handle the authentication handshake.

#### 1. Create the Docker Registry Secret

Generate a Kubernetes secret containing your Cloudera credentials inside the target namespace:

```bash
kubectl create secret docker-registry cloudera-registry-secret \
  --docker-server=container.repo.cloudera.com \
  --docker-username=<YOUR_CLOUDERA_USERNAME> \
  --docker-password=<YOUR_CLOUDERA_PASSWORD> \
  --namespace=default

```

#### 2. Update your Deployment YAML

You must explicitly tell your deployment manifest to use that credential store when pulling images. Add the `imagePullSecrets` array underneath your pod's `spec` block:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minifi-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minifi-test
  template:
    metadata:
      labels:
        app: minifi-test
    spec:
      serviceAccountName: minifi-controller
      # ADD THIS BLOCK TO AUTHENTICATE WITH THE CLOUDERA REGISTRY:
      imagePullSecrets:
        - name: cloudera-registry-secret
      containers:
      - name: minifi
        image: container.repo.cloudera.com/cloudera/apacheminificpp:latest
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080

```