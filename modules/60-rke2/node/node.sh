# RKE2 on one node: server when NODE_ROLE=admin, agent otherwise.
# Installed from RPM (offline repo) so the SELinux policy comes with it.
if [ "$NODE_ROLE" = admin ]; then svc=rke2-server; else svc=rke2-agent; fi
pkg_install "$svc" rke2-selinux nfs-utils
# pods mount NFS-backed volumes (default StorageClass)
if [ "$(getsebool virt_use_nfs 2>/dev/null | awk '{print $3}')" = off ]; then setsebool -P virt_use_nfs on; fi
restart=0
cfg() { write_file "$@"; if [ "$FILE_CHANGED" = 1 ]; then restart=1; fi; }

# Canal's interfaces must be left alone by NetworkManager.
write_file /etc/NetworkManager/conf.d/rke2-canal.conf 0644 <<NM
[keyfile]
unmanaged-devices=interface-name:flannel*;interface-name:cali*;interface-name:tunl*;interface-name:vxlan.calico;interface-name:vxlan-v6.calico;interface-name:wireguard.cali;interface-name:wg-v6.cali
NM
if [ "$FILE_CHANGED" = 1 ]; then systemctl reload NetworkManager; fi

sysreg="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"
usrreg="$REGISTRY_USER_HOST:$REGISTRY_USER_PORT"

# Every image comes from the admin node. Unqualified / docker.io references try
# the user registry first, then the system registry.
cfg /etc/rancher/rke2/registries.yaml 0600 <<YAML
mirrors:
  docker.io:
    endpoint: ["https://$usrreg", "https://$sysreg"]
  quay.io:
    endpoint: ["https://$sysreg"]
  ghcr.io:
    endpoint: ["https://$sysreg"]
  registry.k8s.io:
    endpoint: ["https://$sysreg"]
configs:
  "$sysreg":
    auth:
      username: pull
      password: "$REGISTRY_PULL_PASSWORD"
    tls:
      ca_file: $CA_FILE
  "$usrreg":
    tls:
      ca_file: $CA_FILE
YAML

if [ "$NODE_ROLE" = admin ]; then
  # OIDC: Keycloak usernames are the unix names; groups get a prefix so they can
  # never collide with built-in groups such as system:masters.
  # Lives under server/etc so the SELinux policy lets kube-apiserver watch it
  # (it reloads this file without a restart). RKE2 mounts it into the pod.
  install -d -m 0700 /var/lib/rancher/rke2/server/etc
  restorecon -R /var/lib/rancher/rke2/server
  cfg /var/lib/rancher/rke2/server/etc/hpc-authentication.yaml 0600 <<YAML
apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
- issuer:
    url: https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM
    audiences: [kubernetes]
    certificateAuthority: |
$(sed 's/^/      /' <<<"$CA_PEM")
  claimMappings:
    username:
      claim: preferred_username
      prefix: ""
    groups:
      claim: groups
      prefix: "$OIDC_GROUP_PREFIX"
  userValidationRules:
  - expression: "!user.username.startsWith('system:')"
    message: "usernames starting with system: are reserved"
YAML
  # Tenant ingress is served only from the admin node.
  cfg /var/lib/rancher/rke2/server/manifests/hpc-traefik-config.yaml 0600 <<YAML
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-traefik
  namespace: kube-system
spec:
  valuesContent: |-
    nodeSelector:
      hpc.io/role: admin
YAML
  cfg /etc/rancher/rke2/config.yaml 0600 <<YAML
node-name: $NODE_NAME
node-ip: $NODE_IP
advertise-address: $NODE_IP
tls-san:
  - $KUBE_API_HOST
  - $NODE_NAME
  - $NODE_NAME.$CLUSTER_DOMAIN
  - $NODE_IP
token: $SERVER_TOKEN
agent-token: $AGENT_TOKEN
system-default-registry: $sysreg
cni: $RKE2_CNI
cluster-cidr: $POD_CIDR
service-cidr: $SERVICE_CIDR
ingress-controller: traefik
selinux: true
write-kubeconfig-mode: "0600"
etcd-snapshot-retention: 10
node-label:
  - hpc.io/role=admin
kube-apiserver-arg:
  - authentication-config=/var/lib/rancher/rke2/server/etc/hpc-authentication.yaml
  # PodNodeSelector pins namespaces to node groups (tenants -> compute nodes).
  - enable-admission-plugins=NodeRestriction,PodNodeSelector
YAML
else
  cfg /etc/rancher/rke2/config.yaml 0600 <<YAML
server: https://$KUBE_API_HOST:9345
token: $AGENT_TOKEN
node-name: $NODE_NAME
node-ip: $NODE_IP
system-default-registry: $sysreg
selinux: true
node-label:
  - hpc.io/role=compute
YAML
fi

systemctl enable -q "$svc"
if ! systemctl is-active -q "$svc"; then
  log "starting $svc (first start pulls images; this takes a few minutes)"
  systemctl start "$svc"
elif [ "$restart" = 1 ]; then
  log "configuration changed; restarting $svc"
  systemctl restart "$svc"
fi

if [ "$NODE_ROLE" = admin ]; then
  for _ in $(seq 120); do
    $KUBECTL get --raw /readyz >/dev/null 2>&1 && break; sleep 5
  done
  $KUBECTL get --raw /readyz >/dev/null || fail "kube-apiserver did not become ready (journalctl -u rke2-server)"
  # admin conveniences: kubectl + helm for root
  ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl
  cmp -s "$DATA_ROOT/bundle/bin/helm" /usr/local/bin/helm || install -m 0755 "$DATA_ROOT/bundle/bin/helm" /usr/local/bin/helm
  write_file /etc/profile.d/hpc-kube.sh 0644 <<'PROFILE'
[ "$(id -u)" = 0 ] && export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
PROFILE
fi
