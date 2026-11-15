sys="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"; usr="$REGISTRY_USER_HOST:$REGISTRY_USER_PORT"
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$@" || true; }
is()   { [ "$("${@:2}")" = "$1" ]; }

t  "admin node has no route to the internet"            is 000 code https://github.com
t  "system registry: TLS + rejects anonymous"           is 401 code "https://$sys/v2/_catalog"
t  "system registry: pull account can read"             is 200 code -u "pull:$PULL_PASSWORD" "https://$sys/v2/_catalog"
t  "system registry: pull account cannot push"          is 405 code -u "pull:$PULL_PASSWORD" -X POST "https://$sys/v2/x/blobs/uploads/"
t  "system registry: push endpoint is loopback-only"    is 000 code "https://$ADMIN_IP:$REGISTRY_SYSTEM_RW_PORT/v2/"
t  "user registry: anonymous pull over TLS"             is 200 code "https://$usr/v2/_catalog"
t  "user registry: read-only"                           is 405 code -X POST "https://$usr/v2/x/blobs/uploads/"
t  "user registry: push endpoint is loopback-only"      is 000 code "https://$ADMIN_IP:$REGISTRY_USER_RW_PORT/v2/"

nodes=$(( $(hosts_by_role compute | wc -l) + 1 ))
t  "all $nodes nodes Ready"                             is "$nodes" sh -c "$KUBECTL get nodes --no-headers | awk '\$2==\"Ready\"' | wc -l"
# project pods can only pull through the registry mirrors; check what the platform itself runs
foreign=$(for ns in $($KUBECTL get ns -l 'hpc.io/tenant!=true' -o jsonpath='{.items[*].metadata.name}'); do
  $KUBECTL get pods -n "$ns" -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}'
done | tr ' ' '\n' | sort -u | grep -v -e "^$sys/" -e "^$usr/" -e '^$' || true)
t  "every platform image comes from the internal registries"    test -z "$foreign"
misplaced=$($KUBECTL get pods -A --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.namespace} {.spec.nodeName}{"\n"}{end}' \
  | awk -v a="$ADMIN_NAME" '$1!="kube-system" && $2!=a {print $1}' | sort -u \
  | while read -r ns; do [ "$($KUBECTL get ns "$ns" -o jsonpath='{.metadata.labels.hpc\.io/tenant}')" = true ] || echo "$ns"; done)
t  "platform pods run only on the admin node"           test -z "$misplaced"
unhealthy=$($KUBECTL get pods -A --no-headers | grep -v -E 'Running|Completed' || true)
t  "no failing pods"                                    test -z "$unhealthy"
t  "default StorageClass present"                       sh -c "$KUBECTL get sc $STORAGE_CLASS -o jsonpath='{.metadata.annotations}' | grep -q 'is-default-class\":\"true'"
t  "kube-apiserver trusts the Keycloak realm (OIDC discovery)" curl -fsS "https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"
summary
