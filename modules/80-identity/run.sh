#!/usr/bin/env bash
# DESC: Keycloak realm + OIDC clients (kubectl, Rancher), Rancher login via Keycloak, platform admins
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)

pw=""
for u in $PLATFORM_ADMIN_USERS; do pw="$pw $u:$(secret "users/$u" 20)"; done
upstream=""
if [ "$UPSTREAM_OIDC_SPOOF" = true ] || [ -n "$UPSTREAM_OIDC_ISSUER" ]; then
  # for a real upstream, put the client secret it issued you in secrets/upstream-oidc-client
  upstream=$(secret upstream-oidc-client)
fi

node_put "$a" "$HPC_ROOT/tools/hpc-sync.py" /usr/local/sbin/hpc-sync 0755
node_run "$a" "$HPC_MODULE_DIR/node/identity.sh" "HPC_PASSWORDS=$pw" \
  "RANCHER_OIDC_SECRET=$(secret rancher-oidc-client)" "RANCHER_ADMIN_PASSWORD=$(secret rancher-admin)" \
  "UPSTREAM_OIDC_SECRET=$upstream"
ok "identity configured (realm '$KEYCLOAK_REALM' at https://$KEYCLOAK_HOST)"
