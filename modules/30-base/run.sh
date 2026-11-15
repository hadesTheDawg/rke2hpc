#!/usr/bin/env bash
# DESC: node baseline: name resolution, CA trust, time, offline dnf repo (served from the admin node)
. "$HPC_ROOT/lib/common.sh"
PKI="$SECRETS_DIR/pki"
[ -s "$PKI/ca.crt" ] || die "run 'hpcctl run pki' first"
a=$(admin_host)

put_ca() { node_put "$1" "$PKI/ca.crt" /etc/pki/ca-trust/source/anchors/hpc-ca.crt 0644; }

# The admin node goes first: it hosts the repo every other node installs from.
put_ca "$a"
node_put "$a" "$PKI/ca.crt"    /etc/pki/hpc/ca.crt 0644
node_put "$a" "$PKI/admin.crt" /etc/pki/hpc/admin.crt 0644
node_put "$a" "$PKI/admin.key" /etc/pki/hpc/admin.key 0600
node_run "$a" "$HPC_MODULE_DIR/node/common.sh"
node_run "$a" "$HPC_MODULE_DIR/node/admin.sh"
ok "$a baseline + repo server"

pids=""
for h in $(all_hosts); do
  [ "$h" = "$a" ] && continue
  ( put_ca "$h" && node_run "$h" "$HPC_MODULE_DIR/node/common.sh" && ok "$h baseline" ) &
  pids="$pids $!"
done
rc=0; for p in $pids; do wait "$p" || rc=1; done
[ $rc -eq 0 ] || die "baseline failed on at least one node"
