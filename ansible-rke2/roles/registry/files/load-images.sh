#!/usr/bin/env bash
# Publish the bundle's images through the loopback push endpoints (runs as root
# on the admin node). Env: BUNDLE PUSH_PASSWORD SYS USR
#   system registry: RKE2 release tarballs + images/system
#   user registry:   images/user
# Tags that are already published are skipped.
set -euo pipefail
B="$BUNDLE"
export REGISTRY_AUTH_FILE=/run/hpc-registry-push.json
trap 'rm -f "$REGISTRY_AUTH_FILE"' EXIT
for r in "$SYS" "$USR"; do skopeo login --username push --password-stdin "$r" <<<"$PUSH_PASSWORD" >/dev/null; done
strip_host() { case "${1%%/*}" in *.*|*:*|localhost) echo "${1#*/}" ;; *) echo "$1" ;; esac; }
present() { skopeo inspect --raw "docker://$1" >/dev/null 2>&1; }
n_new=0; n_skip=0
for z in "$B"/rke2/*.tar.zst; do
  [ -e "$z" ] || { echo "no RKE2 image tarballs in $B/rke2" >&2; exit 1; }
  tar="/var/tmp/$(basename "${z%.zst}")"; refs=""
  for ref in $(zstd -dc "$z" | tar -xO manifest.json | jq -r '.[].RepoTags[]'); do
    if present "$SYS/$(strip_host "$ref")"; then n_skip=$((n_skip+1)); else refs="$refs $ref"; fi
  done
  [ -n "$refs" ] || continue
  echo "unpacking $(basename "$z")"
  zstd -dfq "$z" -o "$tar"
  for ref in $refs; do
    echo "push $ref"
    skopeo copy --quiet --retry-times 2 "docker-archive:$tar:$ref" "docker://$SYS/$(strip_host "$ref")"
    n_new=$((n_new+1))
  done
  rm -f "$tar"
done
load_set() { # <set> <registry>
  local dir="$B/images/$1" file dest
  [ -f "$dir/index.tsv" ] || { echo "no image set '$1' in bundle"; return 0; }
  while IFS=$'\t' read -r file dest; do
    if present "$2/$dest"; then n_skip=$((n_skip+1)); continue; fi
    echo "push $dest ($1)"
    skopeo copy --quiet --retry-times 2 "oci-archive:$dir/$file" "docker://$2/$dest"
    n_new=$((n_new+1))
  done <"$dir/index.tsv"
}
load_set system "$SYS"
load_set user "$USR"
echo "published $n_new new image(s), $n_skip already present"
