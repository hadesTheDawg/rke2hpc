python3 /usr/local/sbin/hpc-sync tenants
pin_platform_namespaces
$KUBECTL -n kube-system create secret tls hpc-apps-tls --cert=/etc/pki/hpc/apps.crt --key=/etc/pki/hpc/apps.key \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
apply_tlsstore
