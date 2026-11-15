# Keycloak (production mode, behind the ingress) with a dedicated PostgreSQL.
# The database lives on the admin node's local disk.
sysreg="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"
dbdir=/var/lib/hpc/keycloak-db

install -d -m 0700 -o 999 -g 999 "$dbdir"
semanage fcontext -a -t container_file_t "$dbdir(/.*)?" 2>/dev/null || true
restorecon -R "$dbdir"

k() { $KUBECTL -n keycloak "$@"; }
k create secret generic keycloak-credentials \
  --from-literal=admin-password="$KEYCLOAK_ADMIN_PASSWORD" --from-literal=db-password="$KEYCLOAK_DB_PASSWORD" \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
k create secret tls keycloak-tls --cert=/etc/pki/hpc/ingress.crt --key=/etc/pki/hpc/ingress.key \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
k create configmap hpc-ca --from-file=ca.crt=/etc/pki/hpc/ca.crt --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

$KUBECTL apply -f - >/dev/null <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hpc-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: keycloak-db
spec:
  capacity: {storage: 10Gi}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: hpc-local
  claimRef: {namespace: keycloak, name: data-keycloak-db-0}
  local: {path: $dbdir}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - {key: kubernetes.io/hostname, operator: In, values: [$NODE_NAME]}
---
apiVersion: v1
kind: Service
metadata: {name: keycloak-db, namespace: keycloak}
spec:
  clusterIP: None
  selector: {app: keycloak-db}
  ports: [{name: postgres, port: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: keycloak-db, namespace: keycloak}
spec:
  serviceName: keycloak-db
  replicas: 1
  selector: {matchLabels: {app: keycloak-db}}
  template:
    metadata: {labels: {app: keycloak-db}}
    spec:
      securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: postgres
        image: $sysreg/library/postgres:$POSTGRES_VERSION
        env:
        - {name: POSTGRES_DB, value: keycloak}
        - {name: POSTGRES_USER, value: keycloak}
        - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-credentials, key: db-password}}}
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
        ports: [{name: postgres, containerPort: 5432}]
        readinessProbe:
          exec: {command: [pg_isready, -U, keycloak, -d, keycloak]}
          periodSeconds: 5
        resources:
          requests: {cpu: 100m, memory: 256Mi}
          limits: {memory: 1Gi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
  - metadata: {name: data}
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: hpc-local
      resources: {requests: {storage: 10Gi}}
---
apiVersion: v1
kind: Service
metadata: {name: keycloak, namespace: keycloak}
spec:
  selector: {app: keycloak}
  ports: [{name: http, port: 8080}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: keycloak, namespace: keycloak}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: keycloak}}
  template:
    metadata: {labels: {app: keycloak}}
    spec:
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      containers:
      - name: keycloak
        image: $sysreg/keycloak/keycloak:$KEYCLOAK_VERSION
        args:
        - start
        - --hostname=https://$KEYCLOAK_HOST
        - --http-enabled=true
        - --proxy-headers=xforwarded
        - --health-enabled=true
        - --db=postgres
        - --db-url=jdbc:postgresql://keycloak-db.keycloak.svc:5432/keycloak
        - --db-username=keycloak
        - --truststore-paths=/etc/hpc-ca/ca.crt
        env:
        - {name: KC_DB_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-credentials, key: db-password}}}
        - {name: KC_BOOTSTRAP_ADMIN_USERNAME, value: admin}
        - {name: KC_BOOTSTRAP_ADMIN_PASSWORD, valueFrom: {secretKeyRef: {name: keycloak-credentials, key: admin-password}}}
        ports:
        - {name: http, containerPort: 8080}
        - {name: management, containerPort: 9000}
        startupProbe:
          httpGet: {path: /health/started, port: management}
          periodSeconds: 5
          failureThreshold: 120
        readinessProbe:
          httpGet: {path: /health/ready, port: management}
          periodSeconds: 10
        livenessProbe:
          httpGet: {path: /health/live, port: management}
          periodSeconds: 20
        resources:
          requests: {cpu: 500m, memory: 1Gi}
          limits: {memory: 2Gi}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
        volumeMounts: [{name: hpc-ca, mountPath: /etc/hpc-ca, readOnly: true}]
      volumes:
      - {name: hpc-ca, configMap: {name: hpc-ca}}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata: {name: keycloak, namespace: keycloak}
spec:
  ingressClassName: traefik
  tls: [{hosts: [$KEYCLOAK_HOST], secretName: keycloak-tls}]
  rules:
  - host: $KEYCLOAK_HOST
    http:
      paths:
      - {path: /, pathType: Prefix, backend: {service: {name: keycloak, port: {number: 8080}}}}
---
# Only the ingress controller may reach Keycloak; only Keycloak may reach its database.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: keycloak, namespace: keycloak}
spec:
  podSelector: {matchLabels: {app: keycloak}}
  policyTypes: [Ingress]
  ingress:
  - from:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
    ports: [{port: 8080}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: keycloak-db, namespace: keycloak}
spec:
  podSelector: {matchLabels: {app: keycloak-db}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {app: keycloak}}}]
    ports: [{port: 5432}]
YAML
k rollout status statefulset/keycloak-db --timeout=300s >/dev/null
k rollout status deployment/keycloak --timeout=600s >/dev/null
for _ in $(seq 60); do
  curl -fsS -o /dev/null "https://$KEYCLOAK_HOST/realms/master/.well-known/openid-configuration" && break; sleep 5
done
curl -fsS -o /dev/null "https://$KEYCLOAK_HOST/realms/master/.well-known/openid-configuration" \
  || fail "Keycloak is not answering on https://$KEYCLOAK_HOST"
