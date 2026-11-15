# Runs on the login node. Everything here goes through the same paths users use:
# kubelogin against Keycloak, kubectl against the API, Rancher through OIDC.
NS_A=${GROUP_A,,}; NS_B=${GROUP_B,,}
issuer="https://$KEYCLOAK_HOST/realms/$KEYCLOAK_REALM"
hub="$REGISTRY_USER_HOST:$REGISTRY_USER_PORT"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

token() { # <unix-user|-> <oidc-user> <password>: ID token via the kubectl login plugin
  local run=(); [ "$1" != - ] && run=(sudo -u "$1" -H)
  "${run[@]}" /usr/local/bin/kubectl-oidc_login get-token --oidc-issuer-url="$issuer" --oidc-client-id=kubernetes \
    --grant-type=password --username="$2" --password="$3" | jq -r .status.token
}
TA=$(token "$USER_A" "$USER_A" "$PW_A"); TB=$(token "$USER_B" "$USER_B" "$PW_B"); TADM=$(token - "$ADMIN_USER" "$ADMIN_PW")
kube() { local tok="$1"; shift; KUBECONFIG=/dev/null kubectl --server "https://$KUBE_API_HOST:6443" \
           --certificate-authority /etc/hpc/kube-ca.crt --token "$tok" "$@"; }
ka() { kube "$TA" -n "$NS_A" "$@"; }
kb() { kube "$TB" -n "$NS_B" "$@"; }
T() { jq -c '.spec.activeDeadlineSeconds = 300' <<<"${1:-{\}}"; }   # test pods clean themselves up after 5 minutes
cleanup() { # wait for deletions: a re-run must not meet objects that are still terminating
  ka delete deploy,job,svc,ing,pod --all --timeout=120s >/dev/null 2>&1 || true
  ka delete pvc --all --timeout=120s >/dev/null 2>&1 || true
  kb delete pod --all --timeout=120s >/dev/null 2>&1 || true
}
cleanup

# ---- accounts on the login node --------------------------------------------------
t  "$USER_A has uid >= $UID_START"                         test "$(id -u "$USER_A")" -ge "$UID_START"
t  "$USER_A is in unix group $GROUP_A"                     sh -c "id -Gn $USER_A | tr ' ' '\n' | grep -qx $GROUP_A"
t  "home of $USER_A is $HOME_ROOT/$USER_A, on NFS, private" sh -c "[ \"\$(getent passwd $USER_A | cut -d: -f6)\" = $HOME_ROOT/$USER_A ] && [ \"\$(stat -f -c %T $HOME_ROOT)\" = nfs ] && [ \"\$(sudo -u $USER_A stat -c %a $HOME_ROOT/$USER_A)\" = 700 ]"
tn "$USER_B cannot read the home of $USER_A"               sudo -u "$USER_B" ls "$HOME_ROOT/$USER_A"
sudo -iu "$USER_A" true 2>/dev/null || true               # first login generates the kubeconfig
tm "kubeconfig of $USER_A points at namespace $NS_A"       "namespace: $NS_A" sudo -u "$USER_A" cat "$HOME_ROOT/$USER_A/.kube/config"
tn "login node carries no cluster-admin credentials"       sh -c 'ls /etc/rancher /var/lib/rancher 2>/dev/null | grep -q .'

# ---- identity ---------------------------------------------------------------------
tm "OIDC username equals the unix name"                    "$USER_A" kube "$TA" auth whoami -o jsonpath='{.status.userInfo.username}'
tm "OIDC groups carry the project group"                   "${OIDC_GROUP_PREFIX}$GROUP_A" kube "$TA" auth whoami -o jsonpath='{.status.userInfo.groups}'

printf 'apiVersion: networking.k8s.io/v1\nkind: NetworkPolicy\nmetadata: {name: allow-all}\nspec: {podSelector: {}, ingress: [{}]}\n' >"$W/allow-all.yaml"
printf 'apiVersion: v1\nkind: PersistentVolumeClaim\nmetadata: {name: toobig}\nspec:\n  accessModes: [ReadWriteOnce]\n  resources: {requests: {storage: 100000Gi}}\n' >"$W/toobig.yaml"
# ---- RBAC isolation ----------------------------------------------------------------
t  "$USER_A can work in $NS_A"                              ka auth can-i create jobs
tn "$USER_A cannot list pods in $NS_B"                     kube "$TA" -n "$NS_B" get pods
tn "$USER_A cannot read secrets in $NS_B"                  kube "$TA" -n "$NS_B" get secrets
tn "$USER_A cannot list namespaces"                        kube "$TA" get namespaces
tn "$USER_A cannot list nodes"                             kube "$TA" get nodes
tn "$USER_A cannot change the project quota"               ka delete resourcequota project-quota
tm "$USER_A cannot remove the network isolation"           "managed by the platform" ka delete networkpolicy project-isolation
tm "$USER_A cannot add network policies"                   "managed by the platform" ka create -f "$W/allow-all.yaml"
tn "$USER_A cannot grant access to the namespace"          ka create rolebinding x --clusterrole=edit --user="$USER_B"
t  "platform admin ($ADMIN_USER) is cluster-admin over OIDC" kube "$TADM" get nodes

# ---- workloads land on compute nodes only -------------------------------------------
cat >"$W/web.yaml" <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: web}
spec:
  parallelism: 3
  completions: 3
  activeDeadlineSeconds: 900
  backoffLimit: 0
  template:
    metadata: {labels: {app: web}}
    spec:
      restartPolicy: Never
      terminationGracePeriodSeconds: 2
      containers:
      - name: web
        image: $hub/library/python:3.13-slim
        command: [python, -m, http.server, "8080"]
        ports: [{containerPort: 8080}]
        volumeMounts: [{name: data, mountPath: /data}]
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: data}
---
apiVersion: v1
kind: Service
metadata: {name: web}
spec:
  selector: {app: web}
  ports: [{port: 8080}]
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: data}
spec:
  accessModes: [ReadWriteMany]
  resources: {requests: {storage: 1Gi}}
YAML
t  "submit a 3-pod job from the user registry with a shared volume" ka apply -f "$W/web.yaml"
t  "its pods become ready"                                 ka wait --for=condition=Ready pod -l app=web --timeout=180s
t  "volume claim is bound (default StorageClass)"          ka wait --for=jsonpath='{.status.phase}'=Bound pvc/data --timeout=60s
placed=$(ka get pods -l app=web -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | tr '\n' ' ')
compute=" $(hosts_by_role compute | tr '\n' ' ')"
t  "pods run on compute nodes only (${placed% })"      sh -c "[ -n '$placed' ] && for n in $placed; do case '$compute' in *\" \$n \"*) ;; *) exit 1 ;; esac; done"
tm "pod pinned to the admin node by nodeSelector is rejected" "conflicts with its namespace node label selector" \
   ka run pin1 --image="$hub/library/busybox:1.37" --restart=Never --overrides="$(T '{"spec":{"nodeSelector":{"hpc.io/role":"admin"}}}')" -- sleep 60
tm "pod pinned to the admin node by nodeName is rejected"  "may not set spec.nodeName" \
   ka run pin2 --image="$hub/library/busybox:1.37" --restart=Never --overrides="$(T "{\"spec\":{\"nodeName\":\"$ADMIN_NAME\"}}")" -- sleep 60
tm "privileged pod is rejected (pod security: $TENANT_POD_SECURITY)" "violates PodSecurity" \
   ka run priv --image="$hub/library/busybox:1.37" --restart=Never --overrides="$(T '{"spec":{"containers":[{"name":"priv","image":"x","securityContext":{"privileged":true}}]}}')" -- sleep 60
tm "hostPath volume is rejected"                           "violates PodSecurity" \
   ka run hp --image="$hub/library/busybox:1.37" --restart=Never --overrides="$(T '{"spec":{"volumes":[{"name":"h","hostPath":{"path":"/"}}]}}')" -- sleep 60

# ---- pod defaults: identity, home directory, hardening ------------------------------------
UID_A=$(id -u "$USER_A"); GID_A=$(getent group "$GROUP_A" | cut -d: -f3); HOME_A="$HOME_ROOT/$USER_A"
podlog() { # <name> <overrides-json> <shell command>: run a one-shot pod as USER_A, print its output
  ka delete pod "$1" --ignore-not-found --timeout=60s >/dev/null 2>&1
  ka run "$1" --image=busybox:1.37 --restart=Never --overrides="$(T "$2")" -- sh -c "$3" >/dev/null 2>&1 || return 1
  ka wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$1" --timeout=90s >/dev/null 2>&1
  ka logs "$1" 2>&1
}
sudo -u "$USER_A" rm -f "$HOME_A/verify-pod" "$HOME_A/verify-deploy" "$HOME_A/verify-svc"
out=$(podlog id1 '{}' 'id -u; id -G; echo $HOME; touch $HOME/verify-pod && echo wrote' | tr '\n' ' ')
t  "pod runs as its submitter: uid $UID_A, project gid $GID_A ($out)" sh -c "case '$out' in '$UID_A '*' $GID_A $HOME_A wrote '|'$UID_A '*' $GID_A '*' $HOME_A wrote ') ;; *) exit 1 ;; esac"
t  "file written by the pod is owned by $USER_A in the NFS home" test "$(sudo -u "$USER_A" stat -c %U "$HOME_A/verify-pod" 2>/dev/null)" = "$USER_A"
spec=$(ka get pod id1 -o json | jq -c '[.spec.securityContext.seccompProfile.type, .spec.containers[0].securityContext.allowPrivilegeEscalation, .spec.containers[0].securityContext.capabilities.drop[0]]')
t  "hardening defaults are filled in ($spec)"             test "$spec" = '["RuntimeDefault",false,"ALL"]'
printf 'apiVersion: batch/v1\nkind: Job\nmetadata: {name: owner}\nspec:\n  activeDeadlineSeconds: 120\n  template:\n    spec:\n      restartPolicy: Never\n      containers:\n      - {name: main, image: "busybox:1.37", command: [sh, -c, "id -u > $HOME/verify-deploy"]}\n' | sed 's/\$HOME/$HOME/' >"$W/owner.yaml"
ka apply -f "$W/owner.yaml" >/dev/null 2>&1
ka wait --for=condition=Complete job/owner --timeout=120s >/dev/null 2>&1
t  "pods created by a Job run as the submitter and write to their home" test "$(sudo -u "$USER_A" cat "$HOME_A/verify-deploy" 2>/dev/null)" = "$UID_A"
out=$(podlog id2 '{"spec":{"securityContext":{"runAsUser":0}}}' "id -u; ls $HOME_A >/dev/null 2>&1 && echo readable || echo unreadable" | tr '\n' ' ')
t  "a pod may still ask for root, but root cannot read the home ($out)" test "$out" = "0 unreadable "
out=$(podlog id3 "{\"metadata\":{\"annotations\":{\"hpc.io/user\":\"$USER_B\"}}}" 'echo $HOME; id -u' | tr '\n' ' ')
t  "claiming to be another user is ignored ($out)"        test "$out" = "$HOME_A $UID_A "
ka create deployment owner-d --image=busybox:1.37 -- sh -c 'id -u > $HOME/verify-svc; sleep 600' >/dev/null 2>&1
ka rollout status deploy/owner-d --timeout=120s >/dev/null 2>&1
t  "pods created by a Deployment run as the submitter and write to their home" test "$(sudo -u "$USER_A" cat "$HOME_A/verify-svc" 2>/dev/null)" = "$UID_A"
tm "inline NFS volumes are rejected"                       "project pods may only use" \
   ka run nfs1 --image=busybox:1.37 --restart=Never --overrides="{\"spec\":{\"activeDeadlineSeconds\":300,\"volumes\":[{\"name\":\"x\",\"nfs\":{\"server\":\"$ADMIN_IP\",\"path\":\"$NFS_K8S_EXPORT\"}}]}}" -- true
out=$(podlog net1 '{}' "nc -z -w 3 $ADMIN_IP 2049 && echo nfs-open || echo nfs-blocked; nc -z -w 3 $ADMIN_IP 22 && echo ssh-open || echo ssh-blocked; nc -z -w 3 kubernetes.default.svc 443 && echo api-open || echo api-blocked" | tr '\n' ' ')
t  "pods cannot reach NFS or ssh on the nodes, but can reach the API ($out)" test "$out" = "nfs-blocked ssh-blocked api-open "
ka delete job owner --wait=false >/dev/null 2>&1; ka delete deploy owner-d --wait=false >/dev/null 2>&1; ka delete pod id1 id2 id3 net1 --wait=false >/dev/null 2>&1
sudo -u "$USER_A" rm -f "$HOME_A/verify-pod" "$HOME_A/verify-deploy" "$HOME_A/verify-svc"

# ---- shared quota --------------------------------------------------------------------
cpu=$(ka get resourcequota project-quota -o jsonpath='{.status.hard.limits\.cpu}')
used=$(ka get resourcequota project-quota -o jsonpath='{.status.used.requests\.cpu}')
t  "quota counts the group's running pods (requests.cpu used: $used of $cpu)" test -n "$used" -a "$used" != 0
tm "pod asking for more CPU than the group quota is rejected" "exceeded quota" \
   ka run big --image="$hub/library/busybox:1.37" --restart=Never --overrides="$(T "{\"spec\":{\"containers\":[{\"name\":\"big\",\"image\":\"$hub/library/busybox:1.37\",\"resources\":{\"requests\":{\"cpu\":\"$((cpu+1))\"},\"limits\":{\"cpu\":\"$((cpu+1))\"}}}]}}")" -- sleep 60
stor=$(ka get resourcequota project-quota -o jsonpath='{.status.hard.requests\.storage}')
tm "volume claim beyond the storage quota ($stor) is rejected" "exceeded quota" ka apply -f "$W/toobig.yaml"
tm "NodePort services are not available to projects"       "exceeded quota" ka create service nodeport np --tcp=80:80

# ---- network isolation ------------------------------------------------------------------
web_ip=$(ka get pods -l app=web -o jsonpath='{.items[0].status.podIP}')
probe() { # <kube-fn> <name> <url>: one-shot pod that fetches a URL
  "$1" delete pod "$2" --ignore-not-found --wait=true >/dev/null 2>&1
  "$1" run "$2" --restart=Never --image=busybox:1.37 --quiet -i --rm --overrides="$(T)" -- wget -q -T 5 -O /dev/null "$3" </dev/null
}
t  "same project: pod reaches the service (image pulled by unqualified name)"                 probe ka probe-a "http://web.$NS_A.svc:8080/"
tn "other project: pod cannot reach the service"           probe kb probe-b1 "http://web.$NS_A.svc:8080/"
tn "other project: pod cannot reach the pod IP directly"   probe kb probe-b2 "http://$web_ip:8080/"

# ---- ingress ------------------------------------------------------------------------------
host="web.$NS_A.$APPS_DOMAIN"
t  "ingress under the project's own domain is accepted"    ka create ingress web --class=traefik --rule="$host/*=web:8080"
tm "ingress claiming a platform hostname is rejected"      "ingress hosts must end with" ka create ingress steal --class=traefik --rule="$RANCHER_HOST/*=web:8080"
served() { local i; for i in $(seq 20); do [ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' --resolve "$host:443:$ADMIN_IP" "https://$host/")" = 200 ] && return 0; sleep 2; done; return 1; }
t  "project app is served at https://$host"                served

# ---- Rancher through Keycloak ----------------------------------------------------------------
rlogin() { OIDC_PASSWORD="$2" python3 /usr/local/libexec/hpc/rancher-oidc-login.py "https://$RANCHER_HOST" "$1"; }
rget()   { curl -fsS -m 30 -H "Authorization: Bearer $1" "https://$RANCHER_HOST$2"; }
RA=$(rlogin "$USER_A" "$PW_A" 2>"$W/rlogin.err" || true)
t  "$USER_A logs in to Rancher with the Keycloak account"  test -n "$RA"
if [ -n "$RA" ]; then
  tm "Rancher account of $USER_A carries the unix name"   "$USER_A" rget "$RA" '/v3/principals?me=true'
  seen=$(rget "$RA" /v3/projects | jq -r '[.data[].name] | sort | join(",")')
  t  "$USER_A sees exactly their project in Rancher (sees: $seen)" test "$seen" = "$GROUP_A"
  seen_ns=$(rget "$RA" /k8s/clusters/local/v1/namespaces | jq -r '[.data[].id] | sort | join(",")')
  t  "$USER_A sees only namespace $NS_A in the dashboard (sees: $seen_ns)" test "$seen_ns" = "$NS_A"
  tm "$USER_A sees the project's workloads through Rancher" '"name": "web"' rget "$RA" "/k8s/clusters/local/apis/batch/v1/namespaces/$NS_A/jobs/web"
  curl -fsS -m 30 -H "Authorization: Bearer $RA" -H 'Content-Type: application/json' "https://$RANCHER_HOST/k8s/clusters/local/api/v1/namespaces/$NS_A/pods" \
    -d '{"apiVersion":"v1","kind":"Pod","metadata":{"name":"viarancher"},"spec":{"restartPolicy":"Never","activeDeadlineSeconds":120,"containers":[{"name":"c","image":"busybox:1.37","command":["true"]}]}}' >/dev/null 2>&1
  got=$(ka get pod viarancher -o jsonpath='{.spec.securityContext.runAsUser} {.spec.volumes[?(@.name=="hpc-home")].nfs.path}' 2>/dev/null)
  t  "a pod created through Rancher also runs as $USER_A with their home ($got)" test "$got" = "$UID_A $HOME_ROOT/$USER_A"
  tn "$USER_A cannot read $NS_B through Rancher"           rget "$RA" "/k8s/clusters/local/api/v1/namespaces/$NS_B/pods"
  tn "$USER_A cannot create namespaces through Rancher"    curl -fsS -m 30 -H "Authorization: Bearer $RA" -H 'Content-Type: application/json' -d '{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"escape"}}' "https://$RANCHER_HOST/k8s/clusters/local/api/v1/namespaces"
else
  printf '          %s\n' "$(cat "$W/rlogin.err")"
fi
RADM=$(rlogin "$ADMIN_USER" "$ADMIN_PW" 2>/dev/null || true)
all=$(rget "$RADM" /v3/projects 2>/dev/null | jq -r '[.data[].name] | join(",")' || true)
t  "platform admin sees every project in Rancher"          sh -c "case ,$all, in *,$GROUP_A,*) ;; *) exit 1 ;; esac; case ,$all, in *,$GROUP_B,*) ;; *) exit 1 ;; esac"

cleanup
summary
