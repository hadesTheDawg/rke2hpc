#!/usr/bin/env bash
# DESC: login node: kubectl + OIDC login plugin, kubeconfig generator, sshd policy (SOCKS forwarding)
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
hssh "$a" 'sudo -n cat /var/lib/rancher/rke2/server/tls/server-ca.crt' >"$tmp"
[ -s "$tmp" ] || die "could not read the Kubernetes CA from $a (is RKE2 deployed?)"

for h in $(hosts_by_role login); do
  node_put "$h" "$tmp" /etc/hpc/kube-ca.crt 0644
  node_put "$h" "$BUNDLE_DIR/bin/kubectl" /usr/local/bin/kubectl 0755
  node_put "$h" "$BUNDLE_DIR/bin/kubectl-oidc_login" /usr/local/bin/kubectl-oidc_login 0755
  node_put "$h" "$HPC_MODULE_DIR/files/hpc-kubeconfig" /usr/local/bin/hpc-kubeconfig 0755
  node_run "$h" "$HPC_MODULE_DIR/node/login.sh"
  ok "$h: kubectl ready"
done
