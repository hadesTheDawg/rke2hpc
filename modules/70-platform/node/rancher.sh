# Rancher (dashboards) from the bundled chart; every image comes from the system registry.
sysreg="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
k() { $KUBECTL -n cattle-system "$@"; }

k create secret tls tls-rancher-ingress --cert=/etc/pki/hpc/ingress.crt --key=/etc/pki/hpc/ingress.key \
  --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null
k create secret generic tls-ca --from-file=cacerts.pem=/etc/pki/hpc/ca.crt --dry-run=client -o yaml | $KUBECTL apply -f - >/dev/null

helm upgrade --install rancher "$DATA_ROOT/bundle/charts/rancher-$RANCHER_VERSION.tgz" \
  --namespace cattle-system --wait --timeout 15m -f - >/dev/null <<YAML
hostname: $RANCHER_HOST
replicas: 1
bootstrapPassword: "$RANCHER_ADMIN_PASSWORD"
privateCA: true
ingress:
  ingressClassName: traefik
  tls:
    source: secret
systemDefaultRegistry: $sysreg
rancherImage: $sysreg/rancher/rancher
useBundledSystemChart: true
YAML
k rollout status deployment/rancher --timeout=900s >/dev/null

# The deployment owns the admin password (secrets/rancher-admin), so skip the
# interactive first-login steps.
for _ in $(seq 60); do
  admin=$($KUBECTL get users.management.cattle.io -l authz.management.cattle.io/bootstrapping=admin-user -o name 2>/dev/null | head -1)
  [ -n "$admin" ] && break; sleep 5
done
[ -n "$admin" ] || fail "Rancher did not create its admin user"
$KUBECTL patch "$admin" --type merge -p '{"mustChangePassword":false}' >/dev/null
$KUBECTL patch settings.management.cattle.io first-login --type merge -p '{"value":"false"}' >/dev/null 2>&1 || true
$KUBECTL patch settings.management.cattle.io server-url --type merge -p "{\"value\":\"https://$RANCHER_HOST\"}" >/dev/null

for _ in $(seq 60); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' "https://$RANCHER_HOST/ping")" = 200 ] && break; sleep 5
done
[ "$(curl -s -o /dev/null -w '%{http_code}' "https://$RANCHER_HOST/ping")" = 200 ] || fail "Rancher is not answering on https://$RANCHER_HOST"

# Rancher installs its own components (webhook, fleet, cluster-api, ...) through
# helm jobs after it starts. Wait for them, then pin their namespaces.
settled() {
  ! $KUBECTL get pods -n cattle-system --no-headers 2>/dev/null | grep -E '^helm-operation' | grep -qE 'Running|Pending|ContainerCreating|Init' \
    && $KUBECTL get deployment -n cattle-system rancher-webhook >/dev/null 2>&1
}
calm=0
for _ in $(seq 120); do
  if settled; then calm=$((calm+1)); else calm=0; fi
  [ "$calm" -ge 6 ] && break
  sleep 5
done
[ "$calm" -ge 6 ] || log "warning: Rancher is still installing components; re-run this module later to pin them"
pin_platform_namespaces
failed=$($KUBECTL get pods -n cattle-system --no-headers 2>/dev/null | awk '/^helm-operation/ && $3=="Error"' | wc -l)
[ "$failed" -eq 0 ] || log "warning: $failed failed helm-operation pod(s) in cattle-system (kubectl logs -n cattle-system <pod> -c helm)"
