# Baseline applied to every node.

# ---- name resolution: managed block in /etc/hosts ---------------------------
block=$(
  echo "# BEGIN hpc managed"
  while read -r name ip _role; do
    [ -n "$name" ] && echo "$ip $name.$CLUSTER_DOMAIN $name"
  done <<<"$HPC_HOSTS"
  echo "$ADMIN_IP $REGISTRY_SYSTEM_HOST $REGISTRY_USER_HOST $KUBE_API_HOST $RANCHER_HOST $KEYCLOAK_HOST"
  echo "# END hpc managed"
)
{ sed '/^# BEGIN hpc managed$/,/^# END hpc managed$/d' /etc/hosts; echo "$block"; } | write_file /etc/hosts 0644

# ---- trust the site CA --------------------------------------------------------
restorecon /etc/pki/ca-trust/source/anchors/hpc-ca.crt
update-ca-trust extract

# ---- offline package repository ----------------------------------------------
if [ "$NODE_ROLE" = admin ]; then
  repo_url="file://$DATA_ROOT/bundle/rpms"
  [ -d "$DATA_ROOT/bundle/rpms/repodata" ] || fail "bundle missing at $DATA_ROOT/bundle (run 'hpcctl run bundle')"
else
  repo_url="https://$ADMIN_NAME.$CLUSTER_DOMAIN:$REPO_PORT/repo"
fi
write_file /etc/yum.repos.d/hpc-offline.repo 0644 <<REPO
[hpc-offline]
name=HPC offline repository (admin node)
baseurl=$repo_url
enabled=1
gpgcheck=1
gpgkey=$repo_url/RPM-GPG-KEY-distro $repo_url/RPM-GPG-KEY-rancher
metadata_expire=60
REPO
case " $OFFLINE_ROLES " in *" $NODE_ROLE "*)
  # No route to the internet: distro repos would only produce timeouts.
  for f in /etc/yum.repos.d/*.repo; do
    [ "$f" = /etc/yum.repos.d/hpc-offline.repo ] && continue
    grep -q '^enabled=1' "$f" && { sed -i 's/^enabled=1/enabled=0/' "$f"; log "disabled repos in $f"; }
  done ;;
esac

# ---- time -----------------------------------------------------------------------
if [ "$MANAGE_TIME" = true ] && [ "$NODE_ROLE" != admin ]; then
  pkg_install chrony
  write_file /etc/chrony.conf 0644 <<CHRONY
# managed by hpc 30-base
server $ADMIN_NAME.$CLUSTER_DOMAIN iburst
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
CHRONY
  if [ "$FILE_CHANGED" = 1 ]; then systemctl restart chronyd; fi
  systemctl enable -q --now chronyd
fi
