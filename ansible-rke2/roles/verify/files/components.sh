# Optional components: the local chart repository, the upstream identity
# provider, the Trivy operator and the Harvester UI extension. Each block runs
# only when its component is on. Sourced after lib.sh (runs as root on the admin node).
sys="$REGISTRY_SYSTEM_HOST:$REGISTRY_SYSTEM_PORT"

# ---- chart repository (docs/charts.md) --------------------------------------------
if [ -n "$CHARTS_URL" ]; then
  index() { curl -fsS "$CHARTS_URL/index.yaml"; }
  bundled=$(cd "$DATA_ROOT/bundle/charts" && ls -- *.tgz)
  listed() { local i; i=$(index) || return 1; for c in $bundled; do grep -qF "$CHARTS_URL/$c" <<<"$i" || return 1; done; }
  t  "chart repository serves an index of every bundled chart ($(echo "$bundled" | wc -l | tr -d ' ') charts)" listed
  t  "helm installs from it (helm pull rancher from $CHARTS_URL)" sh -c \
     "cd \$(mktemp -d) && /usr/local/bin/helm pull rancher --repo '$CHARTS_URL' --ca-file /etc/pki/hpc/ca.crt && ls rancher-*.tgz"
  if [ "$RANCHER_ENABLED" = true ]; then
    t  "Rancher catalog '$CHARTS_REPO' downloaded the index" test "$($KUBECTL get clusterrepo "$CHARTS_REPO" \
       -o jsonpath='{.status.conditions[?(@.type=="Downloaded")].status}')" = True
  fi
fi

# ---- upstream identity provider (docs/upstream-idp.md) ------------------------------
if [ -n "$UPSTREAM_ALIAS" ]; then
  kc="https://$KEYCLOAK_HOST"
  admin_token() { curl -fsS "$kc/realms/master/protocol/openid-connect/token" -d grant_type=password \
                    -d client_id=admin-cli -d username=admin --data-urlencode "password=$KC_ADMIN_PW" | jq -r .access_token; }
  AT=$(admin_token)
  kcapi() { local m="$1" p="$2"; shift 2; curl -fsS -X "$m" -H "Authorization: Bearer $AT" -H 'Content-Type: application/json' "$kc/admin/realms$p" "$@"; }
  idp() { kcapi GET "/$KEYCLOAK_REALM/identity-provider/instances/$UPSTREAM_ALIAS"; }
  idp_enabled() { idp | jq -e .enabled; }
  idp_issuer()  { idp | jq .config.issuer; }
  t  "identity provider '$UPSTREAM_ALIAS' enabled in realm $KEYCLOAK_REALM" idp_enabled
  [ -z "$UPSTREAM_ISSUER" ] || tm "it trusts issuer $UPSTREAM_ISSUER" "\"$UPSTREAM_ISSUER\"" idp_issuer
  if [ "$UPSTREAM_SPOOF" = true ]; then
    # The simulated provider gets a user with the same name as a flat-file
    # account, and one with a name that has no account.
    sim="$KEYCLOAK_REALM-upstream-sim"
    up_pw=$(openssl rand -hex 12); stranger="hpc-nobody-$(openssl rand -hex 3)"
    sim_user() { # <name>: create (or reset) a user in the simulated provider
      local id
      id=$(kcapi GET "/$sim/users?username=$1&exact=true" | jq -r '.[0].id // empty')
      [ -n "$id" ] || { kcapi POST "/$sim/users" -d "{\"username\":\"$1\",\"enabled\":true,\"email\":\"$1@upstream.example\",\"emailVerified\":true,\"firstName\":\"$1\",\"lastName\":\"upstream\"}" >/dev/null
                        id=$(kcapi GET "/$sim/users?username=$1&exact=true" | jq -r '.[0].id'); }
      kcapi PUT "/$sim/users/$id/reset-password" -d "{\"type\":\"password\",\"value\":\"$up_pw\",\"temporary\":false}" >/dev/null
    }
    sim_user "$USER_A"; sim_user "$stranger"
    up_login() { UPSTREAM_PASSWORD="$up_pw" python3 "$VERIFY_DIR/upstream-login.py" "$kc" "$KEYCLOAK_REALM" "$UPSTREAM_ALIAS" "$1"; }
    tm "upstream login as $USER_A lands on the flat-file account $USER_A" "$USER_A" up_login "$USER_A"
    tn "upstream login of $stranger (not in the flat file) is refused" up_login "$stranger"
    sid=$(kcapi GET "/$sim/users?username=$stranger&exact=true" | jq -r '.[0].id // empty')
    [ -z "$sid" ] || kcapi DELETE "/$sim/users/$sid" >/dev/null
    no_account() { [ "$(kcapi GET "/$KEYCLOAK_REALM/users?username=$stranger&exact=true" | jq length)" = 0 ]; }
    t  "no account was created for $stranger" no_account
  fi
fi

# ---- Trivy operator (docs/trivy.md) ------------------------------------------------
if [ "$TRIVY_ENABLED" = true ]; then
  t  "trivy-operator running" $KUBECTL -n "$TRIVY_NS" rollout status deploy/trivy-operator --timeout=120s
  t  "its images come from the system registry" sh -c "! $KUBECTL -n $TRIVY_NS get deploy trivy-operator \
     -o jsonpath='{.spec.template.spec.containers[*].image}' | tr ' ' '\n' | grep -v '^$sys/'"
  t  "scanner image and vulnerability DB point at the system registry" sh -c "$KUBECTL -n $TRIVY_NS get cm trivy-operator-trivy-config \
     -o jsonpath='{.data.trivy\.repository} {.data.trivy\.dbRepository}' | grep -q '^$sys/aquasec/trivy $sys/aquasec/trivy-db\$'"
  # The first reports take a few minutes on a new install (one scan job per image).
  reports() { $KUBECTL get vulnerabilityreports -A --no-headers 2>/dev/null | wc -l; }
  for _ in $(seq 60); do [ "$(reports)" -gt 0 ] && break; sleep 10; done
  t  "vulnerability reports exist ($(reports) so far): scans pulled images and the DB offline" test "$(reports)" -gt 0
  kc_report() { $KUBECTL -n keycloak get vulnerabilityreports -o json \
    | jq -e '[.items[] | select(.report.artifact.repository | test("keycloak/keycloak$"))] | length > 0'; }
  for _ in $(seq 30); do kc_report >/dev/null 2>&1 && break; sleep 10; done
  t  "Keycloak's image has a vulnerability report" kc_report
  t  "configuration audit reports exist" sh -c "[ \$($KUBECTL get configauditreports -A --no-headers 2>/dev/null | wc -l) -gt 0 ]"
  nsa=$($KUBECTL get ns -l "hpc.io/project=$GROUP_A" -o jsonpath='{.items[0].metadata.name}')
  can() { $KUBECTL auth can-i list vulnerabilityreports.aquasecurity.github.io -n "$1" --as verify-probe --as-group "$OIDC_GROUP_PREFIX$GROUP_A"; }
  t  "project $GROUP_A can read the reports of its namespace" can "$nsa"
  tn "project $GROUP_A cannot read kube-system's reports" can kube-system
  t  "it reports only: no admission webhook" sh -c "! $KUBECTL get validatingwebhookconfigurations,mutatingwebhookconfigurations -o name | grep -qi trivy"
fi

# ---- Harvester UI extension (docs/harvester.md) -------------------------------------
if [ "$HARVESTER_UI" = true ]; then
  t  "Harvester UI extension served by the admin node" curl -fsS -o /dev/null "$HARVESTER_UI_URL/$HARVESTER_UI_VERSION.tgz"
  t  "Rancher fetched and cached it" test "$($KUBECTL -n cattle-ui-plugin-system get uiplugin harvester -o jsonpath='{.status.cacheState}')" = cached
  # Rancher lists extensions only to logged-in users (unless noAuth): as the platform admin.
  rtok=$(OIDC_PASSWORD="$ADMIN_PW" python3 "$VERIFY_DIR/rancher-oidc-login.py" "https://$RANCHER_HOST" "$ADMIN_USER" 2>/dev/null || true)
  t  "Rancher serves it to logged-in browsers" curl -fsS -o /dev/null -H "Authorization: Bearer $rtok" \
     "https://$RANCHER_HOST/v1/uiplugins/harvester/$HARVESTER_UI_VERSION/plugin/harvester-$HARVESTER_UI_VERSION.umd.min.js"
fi
summary
