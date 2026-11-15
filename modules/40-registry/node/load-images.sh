# Publish the bundle's images through the loopback push endpoints.
#   system registry: RKE2 release tarballs + images/system
#   user registry:   images/user
# Already-published tags are skipped, so this is cheap to re-run.
B="$DATA_ROOT/bundle"
export REGISTRY_AUTH_FILE=/run/hpc-registry-push.json
trap 'rm -f "$REGISTRY_AUTH_FILE"' EXIT
sys="localhost:$REGISTRY_SYSTEM_RW_PORT"
usr="localhost:$REGISTRY_USER_RW_PORT"
for r in "$sys" "$usr"; do
  skopeo login --username push --password-stdin "$r" <<<"$PUSH_PASSWORD" >/dev/null
done

# docker.io/rancher/x:tag -> rancher/x:tag ; rancher/x:tag stays as it is
strip_host() { case "${1%%/*}" in *.*|*:*|localhost) echo "${1#*/}" ;; *) echo "$1" ;; esac; }
present() { skopeo inspect --raw "docker://$1" >/dev/null 2>&1; }
n_new=0; n_skip=0

# RKE2 air-gap tarballs are multi-image docker archives.
for z in "$B"/rke2/*.tar.zst; do
  [ -e "$z" ] || fail "no RKE2 image tarballs in $B/rke2"
  tar="/var/tmp/$(basename "${z%.zst}")"
  refs=""
  for ref in $(zstd -dc "$z" | tar -xO manifest.json | jq -r '.[].RepoTags[]'); do
    dest=$(strip_host "$ref")
    if present "$sys/$dest"; then n_skip=$((n_skip+1)); else refs="$refs $ref"; fi
  done
  [ -n "$refs" ] || continue
  log "unpacking $(basename "$z")"
  zstd -dfq "$z" -o "$tar"
  for ref in $refs; do
    log "push $ref"
    skopeo copy --quiet --retry-times 2 "docker-archive:$tar:$ref" "docker://$sys/$(strip_host "$ref")"
    n_new=$((n_new+1))
  done
  rm -f "$tar"
done

load_set() { # <set> <registry>
  local dir="$B/images/$1" file dest
  [ -f "$dir/index.tsv" ] || { log "no image set '$1' in bundle"; return 0; }
  while IFS=$'\t' read -r file dest; do
    if present "$2/$dest"; then n_skip=$((n_skip+1)); continue; fi
    log "push $dest ($1)"
    skopeo copy --quiet --retry-times 2 "oci-archive:$dir/$file" "docker://$2/$dest"
    n_new=$((n_new+1))
  done <"$dir/index.tsv"
}
load_set system "$sys"
load_set user "$usr"
log "published $n_new new image(s), $n_skip already present"
