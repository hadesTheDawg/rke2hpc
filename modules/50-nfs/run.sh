#!/usr/bin/env bash
# DESC: NFS exports on the admin node (homes, Kubernetes volumes) + home mount on login nodes
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)
home_clients=""; k8s_clients=""
for role in $NFS_HOME_EXPORT_ROLES; do for h in $(hosts_by_role "$role"); do home_clients="$home_clients $(host_ip "$h")"; done; done
for h in $(hosts_by_role admin) $(hosts_by_role compute); do k8s_clients="$k8s_clients $(host_ip "$h")"; done

node_run "$a" "$HPC_MODULE_DIR/node/server.sh" "HOME_CLIENTS=$home_clients" "K8S_CLIENTS=$k8s_clients"
ok "$a exports $NFS_HOME_EXPORT and $NFS_K8S_EXPORT"
for role in $NFS_HOME_CLIENT_ROLES; do
  for h in $(hosts_by_role "$role"); do
    node_run "$h" "$HPC_MODULE_DIR/node/client.sh"
    ok "$h mounts $HOME_ROOT"
  done
done
