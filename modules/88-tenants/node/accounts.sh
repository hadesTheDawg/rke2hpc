# Unix groups and users on a login node, from the id map kept on the admin node.
# Home directories already exist on the NFS export (created on the admin node).
pkg_install jq
declare -A initial
for kv in $HPC_PASSWORDS; do initial["${kv%%:*}"]="${kv#*:}"; done
j() { jq -r "$1" <<<"$ACCOUNTS_JSON"; }

ensure_group() { # <name> <gid>
  local cur; cur=$(getent group "$1" | cut -d: -f3 || true)
  if [ -z "$cur" ]; then groupadd -g "$2" "$1"; log "group $1 ($2)"
  elif [ "$cur" != "$2" ]; then fail "group $1 exists with gid $cur, expected $2"; fi
}
pg=$(j .primary_group.name); pgid=$(j .primary_group.gid)
ensure_group "$pg" "$pgid"
while read -r name gid; do ensure_group "$name" "$gid"; done < <(j '.groups[] | "\(.name) \(.gid)"')

while read -r name uid groups; do
  [ "$groups" = "-" ] && groups=""
  cur=$(id -u "$name" 2>/dev/null || true)
  if [ -z "$cur" ]; then
    useradd -u "$uid" -g "$pg" -G "$groups" -d "$HOME_ROOT/$name" -M -s /bin/bash "$name"
    chpasswd <<<"$name:${initial[$name]}"
    [ "$INITIAL_PASSWORDS_TEMPORARY" = true ] && chage -d 0 "$name"
    log "user $name ($uid) groups: $groups"
  else
    [ "$cur" = "$uid" ] || fail "user $name exists with uid $cur, expected $uid"
    have=$(id -Gn "$name" | tr ' ' '\n' | { grep -vx "$pg" || true; } | sort | paste -sd, -)
    want=$(tr ',' '\n' <<<"$groups" | sort | paste -sd, -)
    if [ "$have" != "$want" ]; then usermod -G "$groups" "$name"; log "user $name groups: $groups"; fi
    # an account that came back into the flat file is unlocked again
    if passwd -S "$name" | awk '{exit !($2=="LK")}'; then usermod -U -e '' "$name"; log "user $name unlocked"; fi
  fi
done < <(j '.users[] | "\(.name) \(.uid) \(if (.groups|length)>0 then .groups|join(",") else "-" end)"')

# Users dropped from the flat file keep their uid and home but can no longer log in.
while read -r name; do
  [ -n "$name" ] && id "$name" >/dev/null 2>&1 || continue
  if ! passwd -S "$name" | awk '{exit !($2=="LK")}'; then
    usermod -L -e 1 -G '' "$name"; log "user $name locked (no longer in the flat file)"
  fi
done < <(j '.removed_users[]')

# Project groups known to this deployment; hpc-kubeconfig builds contexts from it.
j '.groups[].name' | write_file /etc/hpc/project-groups 0644
