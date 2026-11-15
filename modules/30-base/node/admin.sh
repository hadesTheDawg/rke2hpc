# Admin-node services that the rest of the baseline depends on:
# repo/artifact server (nginx, TLS), DNS for the cluster domain, time source.
pkg_install nginx policycoreutils-python-utils

# ---- repo + artifact server ----------------------------------------------------
mkdir -p "$DATA_ROOT/www"
install -m 0644 /etc/pki/hpc/ca.crt "$DATA_ROOT/www/ca.crt"
for t in "$DATA_ROOT/www" "$DATA_ROOT/bundle/rpms"; do
  semanage fcontext -a -t httpd_sys_content_t "$t(/.*)?" 2>/dev/null || semanage fcontext -m -t httpd_sys_content_t "$t(/.*)?"
  restorecon -R "$t"
done
write_file /etc/nginx/nginx.conf 0644 <<NGINX
# managed by hpc 30-base: serves the offline dnf repo and the site CA, TLS only.
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;
  access_log /var/log/nginx/access.log;
  sendfile on;
  server_tokens off;
  server {
    listen $ADMIN_IP:$REPO_PORT ssl;
    server_name $ADMIN_NAME.$CLUSTER_DOMAIN;
    ssl_certificate /etc/pki/hpc/admin.crt;
    ssl_certificate_key /etc/pki/hpc/admin.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    root $DATA_ROOT/www;
    location /repo/ { alias $DATA_ROOT/bundle/rpms/; autoindex on; }
  }
}
NGINX
nginx_changed=$FILE_CHANGED
nginx -t -q
systemctl enable -q --now nginx
if [ "$nginx_changed" = 1 ]; then systemctl reload nginx; fi

# ---- DNS for the cluster domain -------------------------------------------------
# Pods and host-network containers do not read /etc/hosts, so the service names
# must be resolvable through DNS. Sites with their own DNS set MANAGE_DNS=false.
if [ "$MANAGE_DNS" = true ]; then
  pkg_install dnsmasq
  write_file /etc/dnsmasq.d/hpc.conf 0644 <<DNS
# managed by hpc 30-base
listen-address=127.0.0.1,$ADMIN_IP
bind-interfaces
no-resolv
domain-needed
bogus-priv
domain=$CLUSTER_DOMAIN
local=/$CLUSTER_DOMAIN/
expand-hosts
# tenant applications: <app>.<namespace>.$APPS_DOMAIN -> ingress on the admin node
address=/$APPS_DOMAIN/$ADMIN_IP
DNS
  systemctl enable -q dnsmasq
  # /etc/hosts is the zone data, so always restart to pick up inventory changes.
  systemctl restart dnsmasq
fi

# ---- time source ------------------------------------------------------------------
if [ "$MANAGE_TIME" = true ]; then
  pkg_install chrony
  write_file /etc/chrony.conf 0644 <<CHRONY
# managed by hpc 30-base: the admin node is the cluster's time reference.
# Add "server <upstream> iburst" lines here if the site has an NTP source.
local stratum 10
allow $CLUSTER_CIDR
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync
logdir /var/log/chrony
CHRONY
  if [ "$FILE_CHANGED" = 1 ]; then systemctl restart chronyd; fi
  systemctl enable -q --now chronyd
fi
