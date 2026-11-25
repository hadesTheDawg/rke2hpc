#!/usr/bin/env bash
# Import your own RPMs into the cluster's package repository "hpc-local"
# (docs/rpms.md). Copies them into the site's rpms directory next to the
# inventory, then runs rpms.yml, which checks them on the admin node, indexes
# the repository and points every node at it.
#
#   ./import-rpms.sh -i inventories/<site> [options] <file.rpm | directory>...
#   ./import-rpms.sh -i inventories/<site> --list
#   ./import-rpms.sh -i inventories/<site> --remove <file.rpm | glob>...
#   ./import-rpms.sh -i inventories/<site>            (no files: publish what is there)
#
# Options:
#   -i DIR          site inventory directory (or its hosts.yml)
#   --dir DIR       rpms directory, if hpc_local_rpms_dir is not <inventory>/rpms
#   --install PKG   also install (or update to the newest imported version) PKG
#                   now; repeat it or give a comma list
#   --on HOSTS      where --install installs: an inventory pattern, default all
#                   cluster nodes (rke2_servers:rke2_agents); e.g. rke2_agents, cn001
#   --no-apply      only copy; publish later with rpms.yml or site.yml
#   -- ARGS         passed to ansible-playbook (e.g. -- --check --diff)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
die() { echo "import-rpms: $*" >&2; exit 1; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

inv="" dir="" install="" on="rke2_servers:rke2_agents" apply=1 mode=import
files=() extra=()
while [ $# -gt 0 ]; do
  case "$1" in
    -i) inv="${2:?-i needs a directory}"; shift 2 ;;
    --dir) dir="${2:?--dir needs a directory}"; shift 2 ;;
    --install) install="$install,${2:?--install needs a package name}"; shift 2 ;;
    --on) on="${2:?--on needs a host pattern}"; shift 2 ;;
    --no-apply) apply=0; shift ;;
    --list) mode=list; shift ;;
    --remove) mode=remove; shift ;;
    -h|--help) usage 0 ;;
    --) shift; extra=("$@"); break ;;
    -*) echo "unknown option $1" >&2; usage 2 ;;
    *) files+=("$1"); shift ;;
  esac
done
[ -n "$inv" ] || { echo "missing -i inventories/<site>" >&2; usage 2; }
[ -f "$inv" ] && inv=$(dirname "$inv")
[ -f "$inv/hosts.yml" ] || die "$inv/hosts.yml not found"
inv=$(cd "$inv" && pwd)
dir="${dir:-$inv/rpms}"
mkdir -p "$dir"

is_rpm() { [ "$(head -c 4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = edabeedb ]; }
describe() { # name-version-release.arch when rpm(8) is on this machine, else the file name
  if command -v rpm >/dev/null 2>&1; then rpm -qp --nosignature --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$1" 2>/dev/null || basename "$1"
  else basename "$1"; fi
}

case "$mode" in
  list)
    n=0
    for f in "$dir"/*.rpm; do
      [ -e "$f" ] || continue
      printf '%-60s %8s\n' "$(describe "$f")" "$(du -h "$f" | cut -f1)"; n=$((n+1))
    done
    echo "$n RPM(s) in $dir"
    exit 0 ;;
  remove)
    [ ${#files[@]} -gt 0 ] || die "--remove needs file names or globs (see --list)"
    n=0
    for pat in "${files[@]}"; do
      pat=$(basename "$pat"); hit=0
      for f in "$dir"/$pat; do
        [ -e "$f" ] || continue
        rm -f "$f"; echo "removed $(basename "$f")"; n=$((n+1)); hit=1
      done
      [ $hit = 1 ] || echo "no match for $pat in $dir" >&2
    done
    [ $n -gt 0 ] || die "nothing removed" ;;
  import)
    list=()
    for a in ${files[@]+"${files[@]}"}; do
      if [ -d "$a" ]; then
        while IFS= read -r f; do list+=("$f"); done < <(find "$a" -type f -name '*.rpm' | sort)
      elif [ -f "$a" ]; then list+=("$a")
      else die "$a: no such file or directory"; fi
    done
    bad=0
    for f in ${list[@]+"${list[@]}"}; do
      case "$f" in
        *.src.rpm) echo "skip $f: source package (import the binary RPMs built from it)" >&2; bad=1; continue ;;
        *.rpm) ;;
        *) echo "skip $f: file name does not end in .rpm" >&2; bad=1; continue ;;
      esac
      is_rpm "$f" || { echo "skip $f: not an RPM file" >&2; bad=1; continue; }
      dest="$dir/$(basename "$f")"
      if [ -f "$dest" ] && cmp -s "$f" "$dest"; then echo "unchanged $(basename "$f")"
      elif [ -f "$dest" ]; then cp -p "$f" "$dest"; echo "replaced  $(describe "$dest")"
      else cp -p "$f" "$dest"; echo "added     $(describe "$dest")"; fi
    done
    [ $bad = 0 ] || die "some files were not imported (see above); nothing published"
    ;;
esac

[ $apply = 1 ] || { echo "$dir updated; publish with: ansible-playbook -i $inv/hosts.yml rpms.yml (or the next site.yml)"; exit 0; }

ev="{}"
if [ -n "$install" ]; then
  pk=""
  for p in $(echo "$install" | tr ',' ' '); do pk="$pk\"$p\","; done
  ev="{\"hpc_rpms_install\": [${pk%,}], \"hpc_rpms_install_hosts\": \"$on\"}"
fi
[ "$dir" = "$inv/rpms" ] || ev=$(printf '%s' "$ev" | sed "s|^{|{\"hpc_local_rpms_dir\": \"$dir\", |; s|, }$|}|")
cd "$here"
set -x
exec ansible-playbook -i "$inv/hosts.yml" rpms.yml -e "$ev" ${extra[@]+"${extra[@]}"}
