#!/usr/bin/env bash
# DESC: download everything the air-gapped side needs into .cache/bundle and ship it to the admin node
# Usage: hpcctl run bundle [fetch|push]   (default: both)
# `fetch` needs internet on the deployer and on RPM_FETCH_HOST; it is incremental,
# so re-running after a version bump only downloads what changed.
. "$HPC_ROOT/lib/common.sh"

B="$BUNDLE_DIR"
kube_version="${RKE2_VERSION%%+*}"                       # v1.36.6
rke2_urlver=$(printf '%s' "$RKE2_VERSION" | sed 's/+/%2B/')
rke2_rpmver=$(printf '%s' "${RKE2_VERSION#v}" | sed 's/+/~/')   # 1.36.6~rke2r1

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

fetch() { # fetch <url> <dest> [sha256]  (skips files that are already present and valid)
  local url="$1" dest="$2" sum="${3:-}"
  if [ -s "$dest" ] && { [ -z "$sum" ] || [ "$(sha256_of "$dest")" = "$sum" ]; }; then return; fi
  info "fetch $(basename "$dest")"
  mkdir -p "$(dirname "$dest")"
  curl -fL --retry 5 --retry-delay 2 --retry-all-errors -C - -sS -o "$dest.part" "$url"
  if [ -n "$sum" ] && [ "$(sha256_of "$dest.part")" != "$sum" ]; then rm -f "$dest.part"; die "checksum mismatch for $url"; fi
  mv "$dest.part" "$dest"
}
remote_sum() { curl -fsSL --retry 3 "$1" | awk '{print $1; exit}'; }

fetch_binaries() {
  step "binaries"
  local tmp; tmp=$(mktemp -d); mkdir -p "$B/bin" "$B/dl"
  local u
  u="https://github.com/distribution/distribution/releases/download/v$REGISTRY_VERSION/registry_${REGISTRY_VERSION}_linux_$ARCH.tar.gz"
  fetch "$u" "$B/dl/registry-$REGISTRY_VERSION.tar.gz" "$(remote_sum "$u.sha256")"
  tar -xzf "$B/dl/registry-$REGISTRY_VERSION.tar.gz" -C "$tmp" registry && install -m 0755 "$tmp/registry" "$B/bin/registry"

  u="https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz"
  fetch "$u" "$B/dl/helm-$HELM_VERSION.tar.gz" "$(remote_sum "$u.sha256sum")"
  tar -xzf "$B/dl/helm-$HELM_VERSION.tar.gz" -C "$tmp" "linux-$ARCH/helm" && install -m 0755 "$tmp/linux-$ARCH/helm" "$B/bin/helm"

  u="https://dl.k8s.io/release/$kube_version/bin/linux/$ARCH/kubectl"
  fetch "$u" "$B/dl/kubectl-$kube_version" "$(remote_sum "$u.sha256")"
  install -m 0755 "$B/dl/kubectl-$kube_version" "$B/bin/kubectl"

  u="https://github.com/int128/kubelogin/releases/download/$KUBELOGIN_VERSION/kubelogin_linux_$ARCH.zip"
  fetch "$u" "$B/dl/kubelogin-$KUBELOGIN_VERSION.zip" "$(remote_sum "$u.sha256")"
  unzip -oq "$B/dl/kubelogin-$KUBELOGIN_VERSION.zip" kubelogin -d "$tmp" && install -m 0755 "$tmp/kubelogin" "$B/bin/kubectl-oidc_login"
  rm -rf "$tmp"
}

fetch_rke2() {
  step "RKE2 $RKE2_VERSION image tarballs"
  local base="https://github.com/rancher/rke2/releases/download/$rke2_urlver" sums f
  mkdir -p "$B/rke2"
  curl -fsSL --retry 3 -o "$B/rke2/sha256sum-$ARCH.txt" "$base/sha256sum-$ARCH.txt"
  for f in "rke2-images-core.linux-$ARCH.tar.zst" "rke2-images-$RKE2_CNI.linux-$ARCH.tar.zst"; do
    fetch "$base/$f" "$B/rke2/$f" "$(awk -v f="$f" '$2==f {print $1}' "$B/rke2/sha256sum-$ARCH.txt")"
  done
  # drop tarballs from other versions/CNIs so the bundle only carries what is deployed
  for f in "$B"/rke2/*.tar.zst; do
    case "$(basename "$f")" in "rke2-images-core.linux-$ARCH.tar.zst"|"rke2-images-$RKE2_CNI.linux-$ARCH.tar.zst") ;; *) rm -f "$f" ;; esac
  done
  echo "$RKE2_VERSION" >"$B/rke2/VERSION"
}

fetch_charts() {
  step "helm charts"
  fetch "https://releases.rancher.com/server-charts/stable/rancher-$RANCHER_VERSION.tgz" "$B/charts/rancher-$RANCHER_VERSION.tgz"
  fetch "https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/releases/download/nfs-subdir-external-provisioner-$NFS_PROVISIONER_CHART_VERSION/nfs-subdir-external-provisioner-$NFS_PROVISIONER_CHART_VERSION.tgz" \
    "$B/charts/nfs-subdir-external-provisioner-$NFS_PROVISIONER_CHART_VERSION.tgz"
}

# Each image becomes one OCI archive plus a line in index.tsv: "<file>\t<repo:tag>".
# The admin node later pushes them into the matching registry.
fetch_images() { # fetch_images <set> <list-file>
  local set="$1" list="$2" dir="$B/images/$1" ref dest file wanted=""
  step "container images: $set"
  need skopeo
  mkdir -p "$dir"; : >"$dir/index.tsv.new"
  while IFS= read -r ref; do
    case "$ref" in ''|'#'*) continue ;; esac
    ref=$(eval "printf '%s' \"$ref\"")                  # expand ${VAR} from site.env
    case "${ref%%/*}" in *.*|*:*) dest="${ref#*/}" ;; *) dest="$ref" ;; esac   # strip the registry host
    file="$(printf '%s' "$dest" | tr '/:' '__').tar"
    if [ ! -s "$dir/$file" ]; then
      info "pull $ref"
      skopeo copy --quiet --retry-times 3 --override-os linux --override-arch "$ARCH" \
        "docker://$ref" "oci-archive:$dir/$file.part:$dest"
      mv "$dir/$file.part" "$dir/$file"
    fi
    printf '%s\t%s\n' "$file" "$dest" >>"$dir/index.tsv.new"
    wanted="$wanted $file"
  done <"$list"
  mv "$dir/index.tsv.new" "$dir/index.tsv"
  for file in "$dir"/*.tar; do                          # prune archives no longer listed
    [ -e "$file" ] || continue
    case " $wanted " in *" $(basename "$file") "*) ;; *) rm -f "$file" ;; esac
  done
}

fetch_rpms() {
  step "RPMs (resolved on $RPM_FETCH_HOST)"
  local pkgs
  pkgs=$(grep -v '^[[:space:]]*#' "$HPC_ROOT/config/rpms.txt" | awk 'NF {print $1}' | tr '\n' ' ')
  node_run "$RPM_FETCH_HOST" "$HPC_MODULE_DIR/node/fetch-rpms.sh" "RPM_PACKAGES=$pkgs" "RKE2_RPM_VERSION=$rke2_rpmver"
  mkdir -p "$B/rpms"
  rsync -rlt --delete -e "ssh -F $(printf '%q' "$HPC_SSH_CONFIG") -o BatchMode=yes -o LogLevel=ERROR" \
    "$RPM_FETCH_HOST:/var/tmp/hpc-rpm-fetch/repo/" "$B/rpms/"
  info "$(ls "$B/rpms" | grep -c '\.rpm$') packages in the offline repo"
}

cmd_fetch() {
  need curl tar unzip rsync
  fetch_binaries
  fetch_rke2
  fetch_charts
  fetch_images system "$HPC_ROOT/config/images-platform.txt"
  fetch_images user   "$HPC_ROOT/config/images-user.txt"
  fetch_rpms
  {
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "arch=$ARCH"; echo "rke2=$RKE2_VERSION"; echo "rancher=$RANCHER_VERSION"
    echo "keycloak=$KEYCLOAK_VERSION"; echo "registry=$REGISTRY_VERSION"
  } >"$B/MANIFEST"
  ok "bundle ready: $B ($(du -sh "$B" | awk '{print $1}'))"
}

cmd_push() {
  [ -f "$B/MANIFEST" ] || die "no bundle at $B; run 'hpcctl run bundle fetch' first"
  local a; a=$(admin_host)
  step "syncing bundle to $a:$DATA_ROOT/bundle"
  hssh "$a" 'command -v rsync >/dev/null' || die "rsync is required on $a"
  node_sync "$a" "$B" "$DATA_ROOT/bundle"
  ok "bundle on $a"
}

case "${1:-all}" in
  fetch) cmd_fetch ;;
  push)  cmd_push ;;
  all)   cmd_fetch; cmd_push ;;
  *) die "usage: hpcctl run bundle [fetch|push]" ;;
esac
