#!/usr/bin/env bash
# Runs as root on the admin node. Env: MANIFEST (the manifest this run would
# build) DATA_ROOT OFFLINE_REPO. Prints one "ok:"/"missing:" line per check and
# finally "deployed" when the bundle need not be fetched or pushed again:
# the admin node has this exact bundle, the registries run, and the cluster's
# system pods run. (Publishing the bundle's images is the registry role's
# step; it works from the admin node's copy and skips what is published.)
set -uo pipefail
want=$(printf "%s" "$MANIFEST")
k="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
bad=0
check() { # <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok: $d"; else echo "missing: $d"; bad=1; fi
}
same() { [ -f "$1" ] && [ "$(cat "$1")" = "$want" ]; }
check "admin node has this bundle ($DATA_ROOT/bundle/MANIFEST)" same "$DATA_ROOT/bundle/MANIFEST"
check "registries running" systemctl is-active --quiet hpc-registry@system-ro hpc-registry@system-rw hpc-registry@user-ro hpc-registry@user-rw
if [ "$OFFLINE_REPO" = True ] || [ "$OFFLINE_REPO" = true ]; then
  check "offline RPM repository" test -s "$DATA_ROOT/bundle/rpms/repodata/repomd.xml"
fi
check "rke2-server running" systemctl is-active --quiet rke2-server
pods() { # every kube-system pod Running or Succeeded, and there are some
  local out; out=$($k -n kube-system get pods --no-headers -o custom-columns=P:.status.phase) || return 1
  [ -n "$out" ] && ! echo "$out" | grep -qvE '^(Running|Succeeded)$'
}
check "system pods running (kube-system)" pods
[ $bad = 0 ] && echo deployed
exit 0
