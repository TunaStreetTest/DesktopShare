## How to Install a Persisted Edge Flow Manager on Kubernetes

To avoid loosing Edge Flow Manager (EFM) data after EFM pod rollouts we need can use `ssb-postgres` to persist our EFM metadata.


### Working with Postges

```bash
kubectl get pods -n cld-streaming | grep postgres
```

Copy the pod name (e.g. `ssb-postgresql-abc123-xyz`).

Now run these one-time psql commands **inside** that pod:

```bash
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "CREATE DATABASE efm;"
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "CREATE USER efm WITH PASSWORD 'efm_password';"
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE efm TO efm;"
kubectl exec -it <ssb-postgresql-pod-name> -n cld-streaming -- psql -U postgres -c "ALTER DATABASE efm OWNER TO efm;"
```

### Create the EFM Database Password Secret

```bash
kubectl create secret generic efm-db-pass \
  --from-literal=password=efm_password \
  --namespace cld-streaming
```

### Pull the Official EFM Docker Image into Minikube

```bash
eval $(minikube docker-env)
docker login container.repo.cloudera.com
docker pull container.repo.cloudera.com/cloudera/efm:2.3.1.0-2
```

Use the exact tag that matches your CSO / CEM entitlement — 2.3.1.0-2 is the one I’m running in the lab right now. Check your Cloudera archive for the latest matching version.

### Working with EFM Deployment YAML

Create these files in your working directory:

`efm-configMap.yaml`

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

`efm-pvc.yaml`

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: efm-agent-binaries
  namespace: cld-streaming
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
  storageClassName: standard
````

`efm-deployment-persisted.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: efm
  namespace: cld-streaming
  labels:
    app: efm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: efm
  template:
    metadata:
      labels:
        app: efm
    spec:
      imagePullSecrets:
      - name: cloudera-registry
      containers:
      - name: efm
        image: container.repo.cloudera.com/cloudera/efm:2.3.1.0-2
        ports:
        - containerPort: 10090
        - containerPort: 9092
        env:
        - name: EF_DB_URL
          value: "jdbc:postgresql://ssb-postgresql.cld-streaming.svc:5432/efm"
        - name: JAVA_OPTS
          value: "-Dspring.datasource.driver-class-name=org.postgresql.Driver -Def.db.driver.class.name=org.postgresql.Driver"
        - name: EF_JAVA_OPTS
          value: "-Dspring.datasource.driver-class-name=org.postgresql.Driver -Def.db.driver.class.name=org.postgresql.Driver"
        - name: EFM_DB_USER
          value: efm
        - name: EFM_DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: efm-db-pass
              key: password
        - name: EFM_ENCRYPTION_PASSWORD
          valueFrom:
            secretKeyRef:
              name: efm-encryption
              key: encryption.password
        resources:
          requests:
            cpu: "250m"
            memory: "4Gi"
          limits:
            cpu: "250m"
            memory: "4Gi"
        volumeMounts:
        - name: agent-binaries
          mountPath: /opt/efm/efm-2.3.1.0-2/agent-deployer/binaries
        - name: efm-config
          mountPath: /opt/efm/efm-2.3.1.0-2/conf/efm.properties
          subPath: efm.properties
          readOnly: true

      volumes:
      - name: agent-binaries
        persistentVolumeClaim:
          claimName: efm-agent-binaries
      - name: efm-config
        configMap:
          name: efm-config
---

apiVersion: v1
kind: Service
metadata:
  name: efm
  namespace: cld-streaming
  labels:
    app: efm
spec:
  type: LoadBalancer
  ports:
  - port: 10090
    targetPort: 10090
    protocol: TCP
    name: efm-ui
  - port: 9092
    targetPort: 9092
    protocol: TCP
    name: metrics
  selector:
    app: efm

```

Apply YAMLs:

```bash
kubectl apply -f efm-configMap.yaml -n cld-streaming
kubectl apply -f efm-pvc.yaml -n cld-streaming
kubectl apply -f efm-deployment.yaml -n cld-streaming
```

### Verify EFM Properties File Path

```bash
EFM_POD=$(kubectl get pod -n cld-streaming -l app=efm -o jsonpath='{.items[0].metadata.name}')
kubectl exec $EFM_POD -n cld-streaming -- find /opt/efm -name efm.properties
```

### Apply Changes When Needed

```bash
kubectl apply -f efm-deployment.yaml -n cld-streaming
kubectl rollout restart deployment/efm -n cld-streaming
kubectl wait --for=condition=ready pod -l app=efm -n cld-streaming --timeout=120s
```

### Verify EFM is using PostgreSQL

```bash
kubectl exec $EFM_POD -n cld-streaming -- sh -c 'find /opt/efm -name efm.properties -exec grep -E "db\.url|db\.driverClass" {} +'
```
   You should now see the `jdbc:postgresql://...` line.