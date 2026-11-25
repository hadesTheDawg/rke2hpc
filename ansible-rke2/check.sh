#!/usr/bin/env bash
# check.sh [inventory]   static checks before a deployment (docs/operations.md)
#
#   - ansible-playbook --syntax-check of every playbook against the inventory
#   - the flat file (projects.txt) and, if set, the saved upstream IdP configuration
#   - bash -n of every shell script, py_compile of every Python file
#   - yamllint, ansible-lint, shellcheck: when installed (or through uvx when
#     uv is installed and CHECK_UVX=1); missing linters are reported, not fatal
#
# Nothing here touches a node. Exit status is non-zero when a check failed.
# Bash 3.2 compatible (macOS /bin/bash).
set -u
cd "$(dirname "$0")" || exit 2
inv="${1:-inventories/example/hosts.yml}"
[ -f "$inv" ] || { echo "no inventory $inv" >&2; exit 2; }
site_dir="$(dirname "$inv")"
fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
skip() { printf '  skip  %s\n' "$1"; }
run()  { # <description> <command...>
  local d="$1" out; shift
  if out=$("$@" 2>&1); then ok "$d"; else bad "$d"; printf '%s\n' "$out" | sed 's/^/        /' | tail -40; fi
}
tool() { # <name>: command to run a linter, or nothing
  if command -v "$1" >/dev/null 2>&1; then echo "$1"
  elif [ "${CHECK_UVX:-0}" = 1 ] && command -v uvx >/dev/null 2>&1; then
    case "$1" in shellcheck) echo "uvx --quiet --from shellcheck-py shellcheck" ;; *) echo "uvx --quiet $1" ;; esac
  fi
}

echo "playbooks ($inv)"
for pb in site.yml bundle.yml tenants.yml verify.yml acct.yml rpms.yml rollback.yml; do
  run "$pb syntax" ansible-playbook -i "$inv" "$pb" --syntax-check
done

echo "site files"
if [ -f "$site_dir/projects.txt" ]; then
  run "flat file $site_dir/projects.txt" python3 roles/tenants/files/hpc_flatfile.py check "$site_dir/projects.txt"
else
  skip "no $site_dir/projects.txt"
fi
idp=$(sed -n 's/^hpc_upstream_oidc_config_file:[[:space:]]*//p' "$site_dir/group_vars/all.yml" 2>/dev/null \
      | sed -e 's/^["'\'']//' -e 's/["'\'']$//' -e "s#{{ *hpc_site_dir *}}#$site_dir#")
if [ -n "$idp" ]; then
  run "upstream IdP configuration $idp" python3 roles/upstream_idp/files/oidc_config.py file "$idp"
fi

echo "scripts"
helpers="roles/hpc_common/files/hpc-pin-namespaces roles/hpc_common/files/hpc-restart-if-stale
  roles/hpc_common/files/hpc-helm-release roles/hpc_common/files/hpc-apply-tlsstore"
n=0; for f in $(find . -name '*.sh' -not -path './.bundle/*') $helpers; do
  [ -f "$f" ] || continue
  head -1 "$f" | grep -q bash || continue
  bash -n "$f" 2>/dev/null || bad "bash -n $f"; n=$((n+1))
done; ok "bash -n ($n scripts)"
n=0; for f in $(find roles -name '*.py') roles/hpc_common/files/hpc-sync.py; do
  python3 -m py_compile "$f" 2>/dev/null || bad "py_compile $f"; n=$((n+1))
done; find roles -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null; ok "python compiles ($n files)"

echo "linters"
t=$(tool yamllint)
if [ -n "$t" ]; then run "yamllint" $t -c .yamllint .; else skip "yamllint not installed (CHECK_UVX=1 to use uvx)"; fi
t=$(tool ansible-lint)
if [ -n "$t" ]; then run "ansible-lint" $t -q; else skip "ansible-lint not installed (CHECK_UVX=1 to use uvx)"; fi
t=$(tool shellcheck)
if [ -n "$t" ]; then
  # shellcheck disable=SC2046
  run "shellcheck" $t -S warning $(find . -name '*.sh' -not -path './.bundle/*') $helpers
else skip "shellcheck not installed"; fi

[ $fail = 0 ] && echo "all checks passed" || echo "some checks failed"
exit $fail
