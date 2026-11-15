#!/usr/bin/env bash
# DESC: private CA + service certificates + generated credentials (local, no hosts touched)
. "$HPC_ROOT/lib/common.sh"
need openssl
. "$HPC_ROOT/lib/pki.sh"

PKI="$SECRETS_DIR/pki"
mkdir -p "$PKI"; chmod 700 "$SECRETS_DIR" "$PKI"
umask 077

# Bring your own CA by placing ca.crt/ca.key in secrets/pki before the first run.
if [ ! -s "$PKI/ca.key" ]; then
  openssl genrsa -out "$PKI/ca.key" 4096 2>/dev/null
  openssl req -x509 -new -key "$PKI/ca.key" -sha256 -days 3650 \
    -subj "/O=$CLUSTER_NAME/CN=$CLUSTER_NAME internal CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" -out "$PKI/ca.crt"
  ok "created CA $PKI/ca.crt"
fi

a=$(admin_host)
# Host services on the admin node: both registries and the repo/artifact server.
issue admin "$REGISTRY_SYSTEM_HOST,$REGISTRY_USER_HOST,$a.$CLUSTER_DOMAIN,$a,localhost,$(admin_ip),127.0.0.1"
# Cluster ingress: Rancher, Keycloak and the tenant application wildcard.
issue ingress "$RANCHER_HOST,$KEYCLOAK_HOST,*.$APPS_DOMAIN"

# Credentials are created on first use; touching them here makes a fresh
# checkout fail early if secrets/ is not writable.
for s in registry-pull registry-push rke2-server-token rke2-agent-token \
         keycloak-admin keycloak-db rancher-admin rancher-oidc-client; do
  secret "$s" >/dev/null
done
ok "credentials present in $SECRETS_DIR"
