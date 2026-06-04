Smart move. Hardcoding credentials in scripts is a one-way ticket to an accidental GitHub leak.

In Bash, you can read environment variables by prefixing the variable name with a **`$`** sign (e.g., `$MY_VAR`). It is highly recommended to wrap them in double quotes (e.g., `"$MY_VAR"`) to prevent the shell from breaking things if your password contains special characters.

Here is how you can rewrite your script to pull these values safely from your local environment:

### The Refactored Bash Script (`setup_k8s.sh`)

```bash
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
kubectl create namespace cld-streaming

kubectl create secret generic cfm-operator-license \
  --from-file=license.txt=./license.txt \
  -n cld-streaming

kubectl create secret docker-registry cloudera-creds \
  --docker-server=container.repository.cloudera.com \
  --docker-username="$CLOUDERA_USER" \
  --docker-password="$CLOUDERA_PASS" \
  -n cld-streaming

# 3. cfm-streaming Namespace & Secrets
kubectl create namespace cfm-streaming

kubectl create secret generic cfm-operator-license \
  --from-file=license.txt=./license.txt \
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

```

---

### How to feed the variables to your script

You have two clean ways to inject these local environment variables without saving them into the script repository:

#### Option A: Export them in your current terminal session

Before executing the script, run these commands in your terminal:

```bash
export CLOUDERA_USER="your_cloudera_username"
export CLOUDERA_PASS="your_cloudera_password"
export NIFI_ADMIN_PASS="admin12345678"

# Run your script
chmod +x setup_k8s.sh
./setup_k8s.sh

```

#### Option B: Use a local `.env` file (Recommended for local dev)

Create a file named `.env` in the same directory (**and add `.env` to your `.gitignore` file immediately!**):

```text
CLOUDERA_USER=your_cloudera_username
CLOUDERA_PASS=your_cloudera_password
NIFI_ADMIN_PASS=admin12345678

```

Then, you can load the variables right before executing the script like this:

```bash
source .env && ./setup_k8s.sh

```