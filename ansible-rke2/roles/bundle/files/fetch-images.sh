#!/usr/bin/env bash
# fetch-images.sh <arch> <dir> <ref>...   (deployer side, needs skopeo)
# One OCI archive per image plus index.tsv ("<file>\t<repo:tag>"); archives that
# are present are kept, archives no longer listed are removed. Prints "changed"
# when it downloaded or removed anything.
set -euo pipefail
arch="$1" dir="$2"; shift 2
mkdir -p "$dir"; : >"$dir/index.tsv.new"; wanted=" "; changed=0
for ref in "$@"; do
  case "${ref%%/*}" in *.*|*:*) dest="${ref#*/}" ;; *) dest="$ref" ;; esac   # strip the registry host
  file="$(printf '%s' "$dest" | tr '/:' '__').tar"
  if [ ! -s "$dir/$file" ]; then
    echo "pull $ref" >&2
    skopeo copy --quiet --retry-times 3 --override-os linux --override-arch "$arch" \
      "docker://$ref" "oci-archive:$dir/$file.part:$dest"
    mv "$dir/$file.part" "$dir/$file"; changed=1
  fi
  printf '%s\t%s\n' "$file" "$dest" >>"$dir/index.tsv.new"
  wanted="$wanted$file "
done
mv "$dir/index.tsv.new" "$dir/index.tsv"
for f in "$dir"/*.tar; do
  [ -e "$f" ] || continue
  case "$wanted" in *" $(basename "$f") "*) ;; *) rm -f "$f"; changed=1 ;; esac
done
[ $changed = 1 ] && echo changed || echo current
