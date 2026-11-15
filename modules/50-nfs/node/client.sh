# Mount the shared home directories.
pkg_install nfs-utils
install -d -m 0755 "$HOME_ROOT"
line="$ADMIN_NAME.$CLUSTER_DOMAIN:$NFS_HOME_EXPORT $HOME_ROOT nfs4 rw,hard,nosuid,nodev,_netdev,nofail 0 0"
{ grep -v "[[:space:]]$HOME_ROOT[[:space:]]" /etc/fstab || true; echo "$line"; } | write_file /etc/fstab 0644
if [ "$FILE_CHANGED" = 1 ]; then systemctl daemon-reload; fi
mountpoint -q "$HOME_ROOT" || mount "$HOME_ROOT"
# let sshd and login shells use home directories that live on NFS
if command -v getsebool >/dev/null 2>&1 && [ "$(getsebool use_nfs_home_dirs | awk '{print $3}')" != on ]; then
  setsebool -P use_nfs_home_dirs on
fi
