# Cluster plumbing the platform services share.
sysreg="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml

# ---- platform namespaces, pinned to the admin node ------------------------------
for ns in $PLATFORM_NAMESPACES; do
  $KUBECTL create namespace "$ns" --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
done
pin_platform_namespaces

# ---- ingress: site certificate as Traefik's default ------------------------------
$KUBECTL -n kube-system create secret tls hpc-ingress-tls \
  --cert=/etc/pki/hpc/ingress.crt --key=/etc/pki/hpc/ingress.key --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
for _ in $(seq 60); do $KUBECTL get crd tlsstores.traefik.io >/dev/null 2>&1 && break; sleep 5; done
apply_tlsstore

# ---- default StorageClass backed by the admin node's NFS export --------------------
# Volumes land in $NFS_K8S_EXPORT/<namespace>/<claim>. Sizes are not enforced by
# NFS itself; the per-project ResourceQuota (requests.storage) is the control.
helm upgrade --install nfs-provisioner \
  "$DATA_ROOT/bundle/charts/nfs-subdir-external-provisioner-$NFS_PROVISIONER_CHART_VERSION.tgz" \
  --namespace hpc-storage --wait --timeout 5m -f - >/dev/null <<YAML
image:
  repository: $sysreg/sig-storage/nfs-subdir-external-provisioner
  tag: $NFS_PROVISIONER_IMAGE_TAG
nfs:
  server: $ADMIN_IP
  path: $NFS_K8S_EXPORT
storageClass:
  name: $STORAGE_CLASS
  defaultClass: true
  archiveOnDelete: true
  pathPattern: "\${.PVC.namespace}/\${.PVC.name}"
  accessModes: ReadWriteMany
YAML
log "storage class '$STORAGE_CLASS' ready"
