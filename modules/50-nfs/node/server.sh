# NFS server on the admin node.
#   $NFS_HOME_EXPORT  home directories; root is squashed for clients
#   $NFS_K8S_EXPORT   backing store for the cluster's default StorageClass; only
#                     cluster nodes may mount it (the provisioner needs root)
pkg_install nfs-utils
install -d -m 0755 "$NFS_HOME_EXPORT" "$NFS_K8S_EXPORT"
{
  echo "# managed by hpc 50-nfs"
  printf '%s' "$NFS_HOME_EXPORT"; for c in $HOME_CLIENTS; do printf ' %s(rw,sync,root_squash,sec=sys)' "$c"; done; echo
  printf '%s' "$NFS_K8S_EXPORT";  for c in $K8S_CLIENTS;  do printf ' %s(rw,sync,no_root_squash,sec=sys)' "$c"; done; echo
} | write_file /etc/exports.d/hpc.exports 0644
systemctl enable -q --now nfs-server
exportfs -ra
