# CNCF distribution, run straight from the release binary under systemd (no
# container runtime needed, so it is available before Kubernetes exists).
#
# Each registry is two processes over the same storage:
#   <name>-ro  cluster-facing, storage in read-only mode  -> nobody can push over the network
#   <name>-rw  loopback only, authenticated               -> how the admin node publishes images
#
#   system-ro  $REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT  TLS + basic auth (account "pull")
#   user-ro    $REGISTRY_USER_HOST:$REGISTRY_USER_PORT      TLS, anonymous pull
pkg_install httpd-tools skopeo zstd

C=/etc/hpc-registry
S="$DATA_ROOT/registry"
id hpc-registry >/dev/null 2>&1 || useradd --system --home-dir "$S" --shell /sbin/nologin hpc-registry
install -d -m 0750 -o hpc-registry -g hpc-registry "$S" "$S/system" "$S/user"
install -d -m 0750 -o root -g hpc-registry "$C"
restart=0

if ! cmp -s "$DATA_ROOT/bundle/bin/registry" /usr/local/bin/registry; then
  install -m 0755 "$DATA_ROOT/bundle/bin/registry" /usr/local/bin/registry
  restorecon /usr/local/bin/registry; restart=1
  log "installed registry $(/usr/local/bin/registry --version 2>&1 | head -1)"
fi

for f in admin.crt admin.key; do
  write_file "$C/$f" 0640 root:hpc-registry <"/etc/pki/hpc/$f"; [ "$FILE_CHANGED" = 1 ] && restart=1
done

# bcrypt salts differ on every run, so only rewrite when the password changed.
htpasswd_file() { # <file> <user> <password>
  if [ -f "$1" ] && htpasswd -vb "$1" "$2" "$3" >/dev/null 2>&1; then return; fi
  htpasswd -Bbn "$2" "$3" | write_file "$1" 0640 root:hpc-registry; restart=1
}
htpasswd_file "$C/pull.htpasswd" pull "$PULL_PASSWORD"
htpasswd_file "$C/push.htpasswd" push "$PUSH_PASSWORD"

config() { # <instance> <addr> <storage> <readonly> <htpasswd-file|none>
  {
    cat <<YAML
version: 0.1
log:
  level: info
storage:
  filesystem:
    rootdirectory: $3
  delete:
    enabled: true
  maintenance:
    readonly:
      enabled: $4
    uploadpurging:
      enabled: false
http:
  addr: $2
  secret: $HTTP_SECRET
  tls:
    certificate: $C/admin.crt
    key: $C/admin.key
    minimumtls: tls1.2
  headers:
    X-Content-Type-Options: [nosniff]
YAML
    if [ "$5" != none ]; then
      cat <<YAML
auth:
  htpasswd:
    realm: $CLUSTER_NAME-$1
    path: $5
YAML
    fi
  } | write_file "$C/$1.yml" 0640 root:hpc-registry
  [ "$FILE_CHANGED" = 1 ] && restart=1
  return 0
}
config system-ro "$ADMIN_IP:$REGISTRY_SYSTEM_PORT"      "$S/system" true  "$C/pull.htpasswd"
config system-rw "127.0.0.1:$REGISTRY_SYSTEM_RW_PORT"   "$S/system" false "$C/push.htpasswd"
config user-ro   "$ADMIN_IP:$REGISTRY_USER_PORT"        "$S/user"   true  none
config user-rw   "127.0.0.1:$REGISTRY_USER_RW_PORT"     "$S/user"   false "$C/push.htpasswd"

write_file /etc/systemd/system/hpc-registry@.service 0644 <<UNIT
[Unit]
Description=HPC container registry (%i)
After=network-online.target
Wants=network-online.target

[Service]
User=hpc-registry
Group=hpc-registry
ExecStart=/usr/local/bin/registry serve $C/%i.yml
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=$S
Environment=OTEL_TRACES_EXPORTER=none

[Install]
WantedBy=multi-user.target
UNIT
if [ "$FILE_CHANGED" = 1 ]; then systemctl daemon-reload; restart=1; fi

for i in system-ro system-rw user-ro user-rw; do
  systemctl enable -q "hpc-registry@$i"
  if [ "$restart" = 1 ]; then systemctl restart "hpc-registry@$i"; else systemctl start "hpc-registry@$i"; fi
done

# wait until all four answer
for url in "https://$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT" "https://localhost:$REGISTRY_SYSTEM_RW_PORT" \
           "https://$REGISTRY_USER_HOST:$REGISTRY_USER_PORT" "https://localhost:$REGISTRY_USER_RW_PORT"; do
  for _ in $(seq 30); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url/v2/" || true)
    case "$code" in 200|401) break ;; esac; sleep 1
  done
  case "$code" in 200|401) log "$url -> $code" ;; *) fail "registry at $url not answering (got '$code')" ;; esac
done
