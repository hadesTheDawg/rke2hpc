# Node-side helpers, prepended to every node script by node_run (runs as root on
# an EL host, modern bash). Site settings and HPC_HOSTS are already defined.

export PATH="/usr/local/bin:/usr/local/sbin:$PATH"   # sudo's secure_path omits /usr/local

log()  { printf '    [%s] %s\n' "${NODE_NAME:-node}" "$*" >&2; }
fail() { printf 'error: [%s] %s\n' "${NODE_NAME:-node}" "$*" >&2; exit 1; }

# write_file <path> <mode> [owner:group]  (content on stdin)
# Only touches the file when the content changed; sets FILE_CHANGED=1/0 so the
# caller can decide whether a service needs a restart.
FILE_CHANGED=0
write_file() {
  local path="$1" mode="$2" owner="${3:-root:root}" tmp
  mkdir -p "$(dirname "$path")"
  tmp=$(mktemp "${path}.XXXXXX")
  cat >"$tmp"
  if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"; chmod "$mode" "$path"; chown "$owner" "$path"; FILE_CHANGED=0; return 0
  fi
  chmod "$mode" "$tmp"; chown "$owner" "$tmp"; mv -f "$tmp" "$path"
  command -v restorecon >/dev/null 2>&1 && restorecon "$path" 2>/dev/null || true
  log "updated $path"
  FILE_CHANGED=1
}

pkg_install() { # install only what is missing, from the offline repo
  local missing=() p
  for p in "$@"; do rpm -q "$p" >/dev/null 2>&1 || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  log "installing: ${missing[*]}"
  dnf -y -q install "${missing[@]}" >/dev/null
}

hosts_by_role() { awk -v r="$1" '$3==r {print $1}' <<<"$HPC_HOSTS"; }

KUBECTL="/var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml"
CA_FILE=/etc/pki/ca-trust/source/anchors/hpc-ca.crt

# Pin every non-project namespace to the admin node and move pods that started
# on a compute node before the pin existed. Safe to call any time.
pin_platform_namespaces() {
  local ns pods
  for ns in $($KUBECTL get ns -l 'hpc.io/tenant!=true' -o jsonpath='{.items[*].metadata.name}'); do
    case " $UNPINNED_NAMESPACES " in *" $ns "*) continue ;; esac
    $KUBECTL annotate namespace "$ns" --overwrite scheduler.alpha.kubernetes.io/node-selector=hpc.io/role=admin >/dev/null
    $KUBECTL label namespace "$ns" --overwrite hpc.io/platform=true >/dev/null
    pods=$($KUBECTL get pods -n "$ns" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName}{"\n"}{end}' | awk -v a="$ADMIN_NAME" '$2!=a {print $1}')
    if [ -n "$pods" ]; then
      log "moving pods in $ns to the admin node: $(echo $pods)"
      $KUBECTL delete pod -n "$ns" $pods --wait=false >/dev/null
    fi
  done
}

# Traefik's TLS store: the site ingress certificate is the default; the per-project
# wildcard certificate (issued by the tenants module) is added once it exists.
apply_tlsstore() {
  local extra=""
  if $KUBECTL -n kube-system get secret hpc-apps-tls >/dev/null 2>&1; then
    extra=$'\n  certificates:\n  - secretName: hpc-apps-tls'
  fi
  $KUBECTL apply -f - >/dev/null <<YAML
apiVersion: traefik.io/v1alpha1
kind: TLSStore
metadata:
  name: default
  namespace: kube-system
spec:
  defaultCertificate:
    secretName: hpc-ingress-tls$extra
YAML
}
