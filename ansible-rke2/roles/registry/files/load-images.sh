#!/usr/bin/env bash
# Publish the bundle's images through the loopback push endpoints (runs as root
# on the admin node). Env: BUNDLE STAMP PUSH_PASSWORD SYS USR
#   system registry: RKE2 release tarballs + images/system
#   user registry:   images/user
# Tags that are already published are skipped. At the end the bundle's
# MANIFEST is copied to $STAMP: the registry role skips this script while the
# two match.
set -euo pipefail
B="$BUNDLE"
export REGISTRY_AUTH_FILE=/run/hpc-registry-push.json
trap 'rm -f "$REGISTRY_AUTH_FILE"' EXIT
for r in "$SYS" "$USR"; do skopeo login --username push --password-stdin "$r" <<<"$PUSH_PASSWORD" >/dev/null; done
strip_host() { case "${1%%/*}" in *.*|*:*|localhost) echo "${1#*/}" ;; *) echo "$1" ;; esac; }
present() { skopeo inspect --raw "docker://$1" >/dev/null 2>&1; }
# FLOATING: "repo:tag ..." whose content changes under the same tag (Trivy DBs):
# present only when the registry holds the same manifest as the archive.
floating() { case " ${FLOATING:-} " in *" $1 "*) return 0 ;; esac; return 1; }
same_digest() { # <oci-archive> <docker ref>
  [ "$(skopeo inspect --raw "oci-archive:$1" 2>/dev/null | sha256sum)" = "$(skopeo inspect --raw "docker://$2" 2>/dev/null | sha256sum)" ]
}
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
    if floating "$dest"; then
      if same_digest "$dir/$file" "$2/$dest"; then n_skip=$((n_skip+1)); continue; fi
    elif present "$2/$dest"; then n_skip=$((n_skip+1)); continue; fi
    echo "push $dest ($1)"
    skopeo copy --quiet --retry-times 2 "oci-archive:$dir/$file" "docker://$2/$dest"
    n_new=$((n_new+1))
  done <"$dir/index.tsv"
}
load_set system "$SYS"
load_set user "$USR"
[ -z "${STAMP:-}" ] || cp -f "$B/MANIFEST" "$STAMP"
echo "published $n_new new image(s), $n_skip already present"
