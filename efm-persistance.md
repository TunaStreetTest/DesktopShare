**✅ Root cause confirmed:** Your EFM pod is **still using the embedded H2 database** (`jdbc:h2:./database/efm`), even though you set `EF_DB_URL` + `EFM_DB_*` + `JAVA_OPTS` in the deployment.

Cloudera EFM (including the official Docker image `efm:2.3.1.0-2`) **ignores** those environment variables for database configuration. It **only** reads the database settings from the file `/opt/efm/conf/efm.properties` (this is documented behavior in all EFM 2.x versions).  
The H2 file lives inside the container filesystem → every `rollout restart` creates a brand-new pod with a fresh/empty database → your EFM data (agents, flows, etc.) gets wiped.

The `ssb-postgresql` instance you already have is the correct persistent backend — we just need to make EFM actually use it.

### Step-by-step fix

1. **Create a ConfigMap with the correct `efm.properties`**  
   Run this (replace `<YOUR_PASSWORD>` with the value from step 1):

   ```bash
apiVersion: v1
kind: ConfigMap
metadata:
  name: efm-config
  namespace: cld-streaming
data:
  efm.properties: |
    # Web Server Properties
    efm.server.address=0.0.0.0
    efm.server.port=10090
    efm.server.servlet.contextPath=/efm

    # Cluster Properties
    efm.cluster.enabled=false

    # Web Server TLS Properties
    efm.server.ssl.enabled=false
    efm.server.ssl.keyStore=./conf/keystore.jks
    efm.server.ssl.keyStoreType=jks
    efm.server.ssl.keyStorePassword=
    efm.server.ssl.keyPassword=
    efm.server.ssl.trustStore=./conf/truststore.jks
    efm.server.ssl.trustStoreType=jks
    efm.server.ssl.trustStorePassword=
    efm.server.ssl.clientAuth=WANT

    # User Authentication Properties
    efm.security.user.auth.enabled=false
    efm.security.user.auth.adminIdentities=admin
    efm.security.user.auth.autoRegisterNewUsers=true
    efm.security.user.auth.authTokenExpiration=12h
    efm.security.user.auth.groups.manager=INTERNAL
    efm.security.user.auth.groups.adminIdentities=
    efm.security.user.auth.groups.filter=.*
    efm.security.user.certificate.enabled=false
    efm.security.user.oidc.enabled=false
    efm.security.user.saml.enabled=false
    efm.security.user.knox.enabled=false
    efm.security.user.proxy.enabled=false

    # Database Properties (PostgreSQL Persistence)
    efm.db.url=jdbc:postgresql://ssb-postgresql.cld-streaming.svc:5432/efm
    efm.db.driverClass=org.postgresql.Driver
    efm.db.username=efm
    efm.db.password=efm_password
    efm.db.maxConnections=50
    efm.db.sqlDebug=false
    efm.db.l2CacheEnabled=false

    # Heartbeat Properties
    efm.heartbeat.maxAgeToKeep=0
    efm.heartbeat.persistContent=false
    efm.heartbeat.kafka.publishEnabled=false

    # Edge Event Retention Properties
    efm.event.cleanupInterval=30s
    efm.event.maxAgeToKeep.debug=0m
    efm.event.maxAgeToKeep.info=1h
    efm.event.maxAgeToKeep.warn=1d
    efm.event.maxAgeToKeep.error=7d

    # Agent Class Flow Monitor Properties
    efm.agentClassMonitor.interval=15s

    # Agent Monitoring Properties
    efm.monitor.maxHeartbeatInterval=5m
    efm.monitor.agentCertExpiryWarningInterval=30d

    # Operation Properties
    efm.operation.monitoring.enabled=true
    efm.operation.monitoring.inQueuedStateTimeoutHeartbeatRate=1.0
    efm.operation.monitoring.inDeployedStateTimeout=5m
    efm.operation.monitoring.inDeployedStateCheckFrequency=1m
    efm.operation.monitoring.rollingBatchOperationsFrequency=10s
    efm.operation.monitoring.rollingBatchOperationsSize=100
    efm.operation.monitoring.rollingOperationsSize.update.asset=10
    efm.operation.monitoring.rollingOperationsSize.update.configuration=100
    efm.operation.monitoring.rollingOperationsSize.update.properties=100
    efm.operation.monitoring.rollingOperationsSize.sync.resource=10

    # Bulletin Registry Properties
    efm.bulletinregistry.agentBulletinMaxAgeToKeep=5m
    efm.bulletinregistry.agentClassBulletinMinAgeToKeep=10s
    efm.bulletinregistry.agentClassBulletinMaxAgeToKeep=5m

    # Metrics Properties
    management.metrics.efm.enabled=true
    management.simple.metrics.export.enabled=false
    management.prometheus.metrics.export.enabled=true
    management.prometheus.metrics.export.descriptions=true
    management.metrics.enable.efm.heartbeat=true
    management.metrics.enable.efm.repo=true
    management.metrics.efm.enableTag.host=true
    management.metrics.efm.enableTag.protocol=false
    management.metrics.efm.enableTag.agentClass=true
    management.metrics.efm.enableTag.agentManifestId=true
    management.metrics.efm.enableTag.agentId=true
    management.metrics.efm.maxTags.agentClass=20
    management.metrics.efm.maxTags.agentManifestId=10
    management.metrics.efm.maxTags.agentId=100
    management.metrics.tags.application=efm
    management.metrics.distribution.percentiles.all=.75,.95,.99

    # Health and Info Properties
    efm.actuator.clusterHealthUpdateFrequency=10s
    efm.actuator.clusterInfoUpdateFrequency=1m
    management.endpoint.health.showDetails=never
    management.endpoint.health.showComponents=always
    management.health.refresh.enabled=false
    management.health.livenessstate.enabled=false
    management.health.readinessstate.enabled=false
    spring.cloud.discovery.client.compositeIndicator.enabled=false

    # EL Specification Properties
    efm.el.specifications.dir=./specs

    # Logging Properties
    logging.pattern.level=%5p [${spring.application.name:},%X{traceId:-},%X{spanId:-}]
    logging.level.com.cloudera.cem.efm=INFO
    logging.level.com.hazelcast=WARN
    logging.level.com.hazelcast.internal.cluster.ClusterService=INFO
    logging.level.com.hazelcast.internal.nio.tcp.TcpIpConnection=ERROR
    logging.level.com.hazelcast.internal.nio.tcp.TcpIpConnector=ERROR

    # General System Settings
    efm.data.transfer.maxFileSize=16MB
    efm.data.transfer.cleanupInterval=1h
    efm.data.transfer.maxAgeToKeep=1d
    efm.data.transfer.maxEntriesToKeep=100
    efm.agentManager.commands.displayLimit=20
    spring.main.banner-mode=log
    efm.asset.s3.downloadRootPath=/tmp/efm-asset-download
    efm.diagnosticBundle.enabled=false
    efm.agent-deployer.security.autoConfiguration=false
    efm.agent-deployer.security.ca.privateKeyPassword=
    spring.servlet.multipart.max-file-size=100MB
    spring.servlet.multipart.max-request-size=100MB
   ```
    Apply the Config Map:

```bash
kubectl apply -f efm-configMap.yaml -n cld-streaming
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
     mountPath: /opt/efm/efm-2.3.1.0-2/conf/efm.properties
     subPath: efm.properties
     readOnly: true
   ```
   (If the exact path is not `/opt/efm/efm-2.3.1.0-2/conf/efm.properties`, run the command in step 4 first and adjust the `mountPath`.)

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



