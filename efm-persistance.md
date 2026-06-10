**✅ Root cause confirmed:** Your EFM pod is **still using the embedded H2 database** (`jdbc:h2:./database/efm`), even though you set `EF_DB_URL` + `EFM_DB_*` + `JAVA_OPTS` in the deployment.

Cloudera EFM (including the official Docker image `efm:2.3.1.0-2`) **ignores** those environment variables for database configuration. It **only** reads the database settings from the file `/opt/efm/conf/efm.properties` (this is documented behavior in all EFM 2.x versions).  
The H2 file lives inside the container filesystem → every `rollout restart` creates a brand-new pod with a fresh/empty database → your EFM data (agents, flows, etc.) gets wiped.

The `ssb-postgresql` instance you already have is the correct persistent backend — we just need to make EFM actually use it.

### Step-by-step fix

1. **Extract your EFM DB password** (so we don’t hard-code it blindly):
   ```bash
   kubectl get secret efm-db-pass -n cld-streaming -o jsonpath='{.data.password}' | base64 --decode
   ```

2. **Create a ConfigMap with the correct `efm.properties`**  
   Run this (replace `<YOUR_PASSWORD>` with the value from step 1):

   ```bash
   cat <<EOF | kubectl apply -n cld-streaming -f -
   apiVersion: v1
   kind: ConfigMap
   metadata:
     name: efm-config
   data:
     efm.properties: |
       # ================== DATABASE ==================
       efm.db.url=jdbc:postgresql://ssb-postgresql.cld-streaming.svc:5432/efm
       efm.db.driverClass=org.postgresql.Driver
       efm.db.username=efm
       efm.db.password=<YOUR_PASSWORD>
       efm.db.maxConnections=50
       efm.db.sqlDebug=false

       # ================== OTHER SETTINGS (keep your existing ones) ==================
       # Add any other properties you need here (e.g. registry, clustering, etc.)
       # The rest of the file will use the defaults from the image.
   EOF
   ```

3. **Update your `efm-deployment.yaml`** (add the ConfigMap mount)

   Add this under `spec.template.spec.volumes` (next to your `agent-binaries` volume):

   ```yaml
   volumes:
   - name: agent-binaries
     persistentVolumeClaim:
       claimName: efm-agent-binaries
   - name: efm-config               # ← NEW
     configMap:
       name: efm-config
   ```

   Add this under the container’s `volumeMounts` (next to the agent-binaries mount):

   ```yaml
   volumeMounts:
   - name: agent-binaries
     mountPath: /opt/efm/agent-deployer/binaries
   - name: efm-config               # ← NEW (this overrides the file)
     mountPath: /opt/efm/conf/efm.properties
     subPath: efm.properties
     readOnly: true
   ```

   (If the exact path is not `/opt/efm/conf/efm.properties`, run the command in step 4 first and adjust the `mountPath`.)

4. **Verify the properties file path** (optional but recommended):
   ```bash
   EFM_POD=$(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}')
   kubectl exec $EFM_POD -n cld-streaming -- find /opt/efm -name efm.properties
   ```

5. **Apply the new deployment**:
   ```bash
   kubectl apply -f efm-deployment.yaml -n cld-streaming
   kubectl rollout restart deployment/efm -n cld-streaming
   kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
   ```

6. **Verify it’s now using PostgreSQL**:
   ```bash
   kubectl exec $EFM_POD -n cld-streaming -- sh -c '
     find /opt/efm -name efm.properties -exec grep -E "db\.url|db\.driverClass" {} +'
   ```
   You should now see the `jdbc:postgresql://...` line.

### Optional: Make sure the `efm` database exists in PostgreSQL
```bash
kubectl exec -it ssb-postgresql-7548cf4766-sqdp2 -n cld-streaming -- psql -U postgres -c "\l" | grep efm
```
If the `efm` database or user doesn’t exist, create it (EFM will auto-create tables on first start):
```sql
CREATE DATABASE efm;
CREATE USER efm WITH PASSWORD '<YOUR_PASSWORD>';
GRANT ALL PRIVILEGES ON DATABASE efm TO efm;
```

After this change, `kubectl rollout restart deployment/efm` will **no longer** wipe your data. The agent binaries PVC you already have is correctly mounted, so that part stays safe too.

Paste the output of the verification command (step 6) after you apply, and I’ll confirm it’s working or tweak anything else (e.g. if the conf path is different). This is the exact pattern used for production Docker/K8s deployments of EFM.