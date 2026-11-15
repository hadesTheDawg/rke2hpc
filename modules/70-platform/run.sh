#!/usr/bin/env bash
# DESC: in-cluster platform: StorageClass (NFS), ingress TLS, Keycloak (+PostgreSQL), Rancher
# Usage: hpcctl run platform [base|keycloak|rancher]   (default: all, in that order)
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)
PKI="$SECRETS_DIR/pki"

put_ingress_cert() {
  node_put "$a" "$PKI/ingress.crt" /etc/pki/hpc/ingress.crt 0644
  node_put "$a" "$PKI/ingress.key" /etc/pki/hpc/ingress.key 0600
}
cmd_base()     { put_ingress_cert; node_run "$a" "$HPC_MODULE_DIR/node/base.sh"; ok "storage class + ingress TLS"; }
cmd_keycloak() {
  put_ingress_cert
  node_run "$a" "$HPC_MODULE_DIR/node/keycloak.sh" \
    "KEYCLOAK_ADMIN_PASSWORD=$(secret keycloak-admin)" "KEYCLOAK_DB_PASSWORD=$(secret keycloak-db)"
  ok "Keycloak at https://$KEYCLOAK_HOST"
}
cmd_rancher()  {
  put_ingress_cert
  node_run "$a" "$HPC_MODULE_DIR/node/rancher.sh" "RANCHER_ADMIN_PASSWORD=$(secret rancher-admin)"
  ok "Rancher at https://$RANCHER_HOST"
}

case "${1:-all}" in
  base)     cmd_base ;;
  keycloak) cmd_keycloak ;;
  rancher)  cmd_rancher ;;
  all)      cmd_base; cmd_keycloak; cmd_rancher ;;
  *) die "usage: hpcctl run platform [base|keycloak|rancher]" ;;
esac
