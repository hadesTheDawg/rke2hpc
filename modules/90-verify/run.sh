#!/usr/bin/env bash
# DESC: acceptance checks: registries, air gap, placement, isolation, quotas, accounting, logins
# Exercises the deployment as real users would. Needs KEYCLOAK_ALLOW_PASSWORD_GRANT=true
# (non-interactive logins) and at least two project groups in the flat file.
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host); l=$(hosts_by_role login | head -1)

# two different projects, one user from each
line() { sed 's/#.*//' "$PROJECTS_FILE" | awk -F: 'NF>=5' | sed -n "$1p"; }
grp()  { line "$1" | awk -F: '{gsub(/ /,"",$1); print $1}'; }
usr()  { line "$1" | awk -F: '{print $NF}' | tr ',' '\n' | awk 'NF {print $1; exit}'; }
ga=$(grp 1); ua=$(usr 1); gb=$(grp 2); ub=$(usr 2)
[ -n "$gb" ] || die "verify needs at least two project groups in $PROJECTS_FILE"
admin_user=$(echo $PLATFORM_ADMIN_USERS | awk '{print $1}')
rc=0
run_checks() { # <host> <script> [KEY=VALUE...]: node script with the test harness prepended
  local host="$1" name="$2" tmp; shift 2
  tmp=$(mktemp); cat "$HPC_MODULE_DIR/node/lib.sh" "$HPC_MODULE_DIR/node/$name.sh" >"$tmp"
  node_run "$host" "$tmp" "$@"; local r=$?; rm -f "$tmp"; return $r
}

step "infrastructure (on $a)"
run_checks "$a" infra "PULL_PASSWORD=$(secret registry-pull)" || rc=1

step "tenants (from $l, as $ua [$ga] and $ub [$gb])"
node_put "$l" "$HPC_ROOT/tools/rancher-oidc-login.py" /usr/local/libexec/hpc/rancher-oidc-login.py 0755
run_checks "$l" tenants \
  "USER_A=$ua" "GROUP_A=$ga" "PW_A=$(secret "users/$ua")" \
  "USER_B=$ub" "GROUP_B=$gb" "PW_B=$(secret "users/$ub")" \
  "ADMIN_USER=$admin_user" "ADMIN_PW=$(secret "users/$admin_user")" || rc=1

step "usage accounting (on $a, acting as $ua [$ga])"
run_checks "$a" accounting "USER_A=$ua" "GROUP_A=$ga" || rc=1

step "user access from outside: ssh password login + SOCKS5 to the dashboards"
pass=0; fail=0
t() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); printf '    PASS  %s\n' "$d"; else fail=$((fail+1)); printf '    FAIL  %s\n' "$d"; fi; }
askpass=$(mktemp); sock_port=$((20000 + RANDOM % 20000)); tunnel=""
trap '[ -n "$tunnel" ] && kill "$tunnel" 2>/dev/null; rm -f "$askpass"' EXIT
printf '#!/bin/sh\ncat "%s"\n' "$SECRETS_DIR/users/$ua" >"$askpass"; chmod 700 "$askpass"
# the site ssh config supplies host and port; authentication is the user's password
user_ssh_opts="-F $HPC_SSH_CONFIG -o User=$ua -o IdentityFile=/dev/null -o IdentitiesOnly=yes -o IdentityAgent=none
  -o PubkeyAuthentication=no -o PreferredAuthentications=password -o ControlMaster=no -o ControlPath=none -o LogLevel=ERROR"
user_ssh() { SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh $user_ssh_opts "$@" </dev/null; }
socks()    { curl -s -m 20 --cacert "$SECRETS_DIR/pki/ca.crt" --socks5-hostname "127.0.0.1:$sock_port" "$@"; }
home_ok()  { [ "$(user_ssh "$l" 'pwd; stat -f -c %T .' | tr '\n' ' ')" = "$HOME_ROOT/$ua nfs " ]; }
rancher_ok()  { [ "$(socks -o /dev/null -w '%{http_code}' "https://$RANCHER_HOST/dashboard/")" = 200 ]; }
keycloak_ok() { socks "https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM/.well-known/openid-configuration" | grep -q device_authorization_endpoint; }
no_onward()   { ! user_ssh "$l" "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 $a true"; }
no_sudo()     { ! user_ssh "$l" 'sudo -n true'; }

t "$ua logs in to $l with a password; home is $HOME_ROOT/$ua on NFS" home_ok
SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=none ssh $user_ssh_opts -N -D "127.0.0.1:$sock_port" "$l" </dev/null >/dev/null 2>&1 &
tunnel=$!
wait_for "SOCKS tunnel" 30 nc -z 127.0.0.1 "$sock_port"
t "Rancher dashboard through the SOCKS5 proxy (TLS verified against the site CA)" rancher_ok
t "Keycloak through the SOCKS5 proxy" keycloak_ok
t "$ua cannot ssh onward to the admin node" no_onward
t "$ua has no sudo on the login node" no_sudo
kill "$tunnel" 2>/dev/null || true; tunnel=""
printf '    %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || rc=1

[ $rc -eq 0 ] && ok "all acceptance checks passed" || die "some acceptance checks failed"
