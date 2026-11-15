# Recorder service for usage accounting. It observes; it enforces nothing.
[ -f /var/lib/hpc/projects.json ] || fail "no parsed flat file yet; run 'hpcctl run tenants' first"
restorecon /usr/local/sbin/hpc-acct
install -d -m 0700 /var/lib/hpc/acct

write_file /etc/hpc/acct.env 0644 <<ENV
# managed by hpc 89-accounting (from config/site.env)
ACCT_POLL_SECONDS=$ACCT_POLL_SECONDS
ACCT_PERIOD_START=$ACCT_PERIOD_START
TENANT_DEFAULT_CPU_REQUEST=$TENANT_DEFAULT_CPU_REQUEST
ENV
env_changed=$FILE_CHANGED

write_file /etc/systemd/system/hpc-acct.service 0644 <<UNIT
[Unit]
Description=HPC job accounting recorder
After=rke2-server.service
Wants=rke2-server.service

[Service]
ExecStart=/usr/bin/python3 /usr/local/sbin/hpc-acct daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
if [ "$FILE_CHANGED" = 1 ]; then systemctl daemon-reload; fi

# An earlier version of this module enforced time limits; remove what it installed.
for n in hpc-tenant-batch-only hpc-tenant-walltime-jobs hpc-tenant-walltime-pods hpc-tenant-walltime-frozen; do
  $KUBECTL delete validatingadmissionpolicybinding,validatingadmissionpolicy "$n" --ignore-not-found >/dev/null 2>&1 || true
done
$KUBECTL -n kube-system delete configmap hpc-accounting --ignore-not-found >/dev/null 2>&1 || true

systemctl enable -q hpc-acct
systemctl restart hpc-acct
sleep 2
systemctl is-active -q hpc-acct || fail "hpc-acct did not start (journalctl -u hpc-acct)"
log "recorder active; $(python3 /usr/local/sbin/hpc-acct status | head -1)"
