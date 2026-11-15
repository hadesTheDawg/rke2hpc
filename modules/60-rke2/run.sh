#!/usr/bin/env bash
# DESC: RKE2 server on the admin node, agents on the compute nodes, images from the system registry
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)
common="REGISTRY_PULL_PASSWORD=$(secret registry-pull)"

node_run "$a" "$HPC_MODULE_DIR/node/node.sh" "$common" \
  "SERVER_TOKEN=$(secret rke2-server-token)" "AGENT_TOKEN=$(secret rke2-agent-token)" \
  "CA_PEM=$(cat "$SECRETS_DIR/pki/ca.crt")"
ok "$a: RKE2 server ready"

pids=""
for h in $(hosts_by_role compute); do
  ( node_run "$h" "$HPC_MODULE_DIR/node/node.sh" "$common" "AGENT_TOKEN=$(secret rke2-agent-token)" && ok "$h: RKE2 agent running" ) &
  pids="$pids $!"
done
rc=0; for p in $pids; do wait "$p" || rc=1; done
[ $rc -eq 0 ] || die "RKE2 agent setup failed on at least one node"

step "waiting for all nodes to be Ready"
n=$(( $(hosts_by_role compute | wc -l) + 1 ))
ready() { [ "$(admin_kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')" -eq "$n" ]; }
wait_for "$n Ready nodes" 600 ready
admin_kubectl get nodes -o wide >&2
