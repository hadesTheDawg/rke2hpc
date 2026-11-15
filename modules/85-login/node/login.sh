# Login node: the only cluster tooling here is kubectl.
pkg_install bash-completion
restorecon /usr/local/bin/kubectl /usr/local/bin/kubectl-oidc_login /usr/local/bin/hpc-kubeconfig

write_file /etc/hpc/kube.env 0644 <<ENV
HPC_CLUSTER_NAME=$CLUSTER_NAME
HPC_KUBE_SERVER=https://$KUBE_API_HOST:6443
HPC_OIDC_ISSUER=https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM
HPC_KUBELOGIN_GRANT=$KUBELOGIN_GRANT
ENV
[ -f /etc/hpc/project-groups ] || : >/etc/hpc/project-groups

kubectl completion bash | write_file /etc/bash_completion.d/kubectl 0644
write_file /etc/profile.d/hpc-kube.sh 0644 <<PROFILE
# project users get a kubeconfig on first login
if [ "\$(id -u)" -ge $UID_START ] && [ ! -e "\$HOME/.kube/config" ] && [ -w "\$HOME" ]; then
  /usr/local/bin/hpc-kubeconfig 2>/dev/null || true
fi
PROFILE
write_file /etc/motd.d/hpc 0644 <<MOTD

  $CLUSTER_NAME cluster login node
    kubectl            your project namespace(s); log in with your cluster account
    dashboards         https://$RANCHER_HOST  (via a SOCKS proxy: ssh -D 1080 <this host>)
    account/password   https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM/account
    user images        $REGISTRY_USER_HOST:$REGISTRY_USER_PORT

MOTD

# sshd: project users may open SOCKS/TCP forwards (to reach the dashboards) and
# nothing else beyond a shell. 10- sorts before the distro/cloud-init drop-ins.
pwauth=no; [ "$LOGIN_SSH_PASSWORD_AUTH" = true ] && pwauth=yes
write_file /etc/ssh/sshd_config.d/10-hpc.conf 0600 <<SSHD
# managed by hpc 85-login
PasswordAuthentication $pwauth
KbdInteractiveAuthentication no
PermitRootLogin no
Match Group hpc-users
  AllowTcpForwarding yes
  X11Forwarding no
  AllowAgentForwarding no
  PermitTunnel no
  GatewayPorts no
SSHD
if [ "$FILE_CHANGED" = 1 ]; then sshd -t && systemctl reload sshd; fi
