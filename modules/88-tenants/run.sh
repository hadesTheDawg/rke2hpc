#!/usr/bin/env bash
# DESC: project groups from config/projects.txt: unix accounts, homes, namespaces, quotas, isolation, logins
# Re-run after every change to the flat file.
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)
[ -f "$PROJECTS_FILE" ] || die "flat file not found: $PROJECTS_FILE"

# One initial password per user, shared by the unix account and Keycloak.
pw=""
for u in $(sed 's/#.*//' "$PROJECTS_FILE" | awk -F: 'NF>=5 {print $NF}' | tr ',' '\n' | awk 'NF {print $1}' | sort -u); do
  case "$u" in *[!a-z0-9_-]*) die "invalid username in $PROJECTS_FILE: $u" ;; esac
  pw="$pw $u:$(secret "users/$u" 20)"
done

# Tenant applications live at <app>.<namespace>.$APPS_DOMAIN. A wildcard only
# covers one label, so the ingress gets a certificate with one wildcard per project.
. "$HPC_ROOT/lib/pki.sh"
sans=""
for g in $(sed 's/#.*//' "$PROJECTS_FILE" | awk -F: 'NF>=5 {gsub(/[ \t]/,"",$1); print tolower($1)}'); do
  sans="$sans,*.$g.$APPS_DOMAIN"
done
[ -n "$sans" ] || die "no project groups in $PROJECTS_FILE"
issue apps "${sans#,}"
node_put "$a" "$PKI/apps.crt" /etc/pki/hpc/apps.crt 0644
node_put "$a" "$PKI/apps.key" /etc/pki/hpc/apps.key 0600

node_put "$a" "$HPC_ROOT/tools/hpc-sync.py" /usr/local/sbin/hpc-sync 0755
node_put "$a" "$PROJECTS_FILE" /etc/hpc/projects.txt 0600
node_run "$a" "$HPC_MODULE_DIR/node/tenants.sh" "HPC_PASSWORDS=$pw"
ok "projects reconciled on the cluster"

accounts=$(hssh "$a" 'sudo -n cat /var/lib/hpc/accounts.json')
for h in $(hosts_by_role login); do
  node_run "$h" "$HPC_MODULE_DIR/node/accounts.sh" "ACCOUNTS_JSON=$accounts" "HPC_PASSWORDS=$pw"
  ok "$h: unix accounts in sync"
done
info "initial passwords: secrets/users/<name>"
