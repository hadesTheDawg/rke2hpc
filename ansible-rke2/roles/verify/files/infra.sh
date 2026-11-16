sys="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"; usr="$REGISTRY_USER_HOST:$REGISTRY_USER_PORT"
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@" || true; }
is()   { [ "$("${@:2}")" = "$1" ]; }

[ "$OFFLINE" = true ] && t "admin node has no route to the internet" is 000 code https://github.com
t  "system registry: TLS + rejects anonymous"           is 401 code "https://$sys/v2/_catalog"
t  "system registry: pull account can read"             is 200 code -u "pull:$PULL_PASSWORD" "https://$sys/v2/_catalog"
t  "system registry: pull account cannot push"          is 405 code -u "pull:$PULL_PASSWORD" -X POST "https://$sys/v2/x/blobs/uploads/"
t  "system registry: push endpoint is loopback-only"    is 000 code "https://$ADMIN_IP:$REGISTRY_SYSTEM_RW_PORT/v2/"
t  "user registry: anonymous pull over TLS"             is 200 code "https://$usr/v2/_catalog"
t  "user registry: read-only"                           is 405 code -X POST "https://$usr/v2/x/blobs/uploads/"
t  "user registry: push endpoint is loopback-only"      is 000 code "https://$ADMIN_IP:$REGISTRY_USER_RW_PORT/v2/"

nodes=$(( $(hosts_by_role compute | wc -l) + 1 ))
t  "all $nodes nodes Ready"                             is "$nodes" sh -c "$KUBECTL get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l"
# project pods can only pull through the registry mirrors; check what the platform itself runs
foreign=$(for ns in $($KUBECTL get ns -l 'hpc.io/tenant!=true' -o jsonpath='{.items[*].metadata.name}'); do
  $KUBECTL get pods -n "$ns" -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
done | tr ' ' '\n' | sort -u | grep -v -e "^$sys/" -e "^$usr/" -e '^$' || true)
t  "every platform image comes from the internal registries"    test -z "$foreign"
misplaced=$($KUBECTL get pods -A --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.namespace} {.spec.nodeName}{"\n"}{end}' \
  | awk -v a="$ADMIN_NAME" -v skip=" $UNPINNED_NAMESPACES " 'index(skip, " " $1 " ")==0 && $2!=a {print $1}' | sort -u \
  | while read -r ns; do [ "$($KUBECTL get ns "$ns" -o jsonpath='{.metadata.labels.hpc\.io/tenant}')" = true ] || echo "$ns"; done)
t  "platform pods run only on the admin node"           test -z "$misplaced"
unhealthy=$($KUBECTL get pods -A --no-headers | grep -v -E 'Running|Completed' || true)
t  "no failing pods"                                    test -z "$unhealthy"
if [ -n "$STORAGE_CLASS" ]; then
t  "default StorageClass '$STORAGE_CLASS' present"       sh -c "$KUBECTL get sc $STORAGE_CLASS -o jsonpath='{.metadata.annotations}' | grep -q 'is-default-class\":\"true'"
fi
t  "kube-apiserver trusts the Keycloak realm (OIDC discovery)" curl -fsS "https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"

# ---- networks: node IP on management, pod overlay on the pod interface -------------
while read -r name role mgmt pod; do
  [ -n "$name" ] || continue
  t  "$name: Kubernetes node IP is the management address ($mgmt)" \
     test "$($KUBECTL get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')" = "$mgmt"
  t  "$name: pod overlay endpoint is the pod-network address ($pod)" \
     test "$($KUBECTL get node "$name" -o jsonpath='{.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip}')" = "$pod"
done <<<"$NODE_NETS"
t  "cluster DNS forwards $CLUSTER_DOMAIN to the admin node" sh -c "$KUBECTL -n kube-system get configmap rke2-coredns-rke2-coredns -o jsonpath='{.data.Corefile}' | grep -q '$CLUSTER_DOMAIN'"

# ---- CephFS driver (when installed) ------------------------------------------------------
if [ "$CEPH_ENABLED" = true ]; then
  ds_ready()    { [ "$($KUBECTL -n "$CEPH_NS" get ds ceph-csi-cephfs-nodeplugin -o jsonpath='{.status.numberReady}')" = "$nodes" ]; }
  ceph_images() { $KUBECTL -n "$CEPH_NS" get pods -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u; }
  ceph_local()  { [ -n "$(ceph_images)" ] && ! ceph_images | grep -v "^$sys/"; }
  t  "CephFS CSI driver registered"                       $KUBECTL get csidriver cephfs.csi.ceph.com
  t  "CephFS node plugin ready on every node ($nodes)"    ds_ready
  t  "CephFS provisioner ready (all sidecars running)"    $KUBECTL -n "$CEPH_NS" rollout status deploy/ceph-csi-cephfs-provisioner --timeout=120s
  t  "every CephFS image comes from the system registry ($(ceph_images | wc -l | tr -d ' ') images)" ceph_local
fi
# ---- admin node state backups (docs/reprovisioning.md) ------------------------------
if [ -n "$BACKUP_DIR" ]; then
  fresh() { [ -n "$(find "$BACKUP_DIR/$1" -maxdepth 1 -type f -name "$2" -mmin -150 | head -1)" ]; }
  t  "etcd snapshot in $BACKUP_DIR from the last 150 minutes"   fresh etcd 'hpc-backup-*'
  t  "accounting database backup from the last 150 minutes"     fresh acct 'acct-*.db'
  t  "backup timer is scheduled"                                systemctl is-active -q hpc-backup.timer
fi
summary
