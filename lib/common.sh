#!/usr/bin/env bash
# Deployer-side helpers shared by bin/hpcctl, the modules and the lab.
# Must stay compatible with bash 3.2 (macOS /bin/bash).

set -euo pipefail

HPC_ROOT="${HPC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export HPC_ROOT

# ---- logging ----------------------------------------------------------------
if [ -t 2 ]; then _c_b=$'\033[1m'; _c_g=$'\033[32m'; _c_y=$'\033[33m'; _c_r=$'\033[31m'; _c_0=$'\033[0m'
else _c_b=; _c_g=; _c_y=; _c_r=; _c_0=; fi
step() { printf '%s==> %s%s\n' "$_c_b" "$*" "$_c_0" >&2; }
info() { printf '    %s\n' "$*" >&2; }
ok()   { printf '%s    ok: %s%s\n' "$_c_g" "$*" "$_c_0" >&2; }
warn() { printf '%s    warn: %s%s\n' "$_c_y" "$*" "$_c_0" >&2; }
die()  { printf '%serror: %s%s\n' "$_c_r" "$*" "$_c_0" >&2; exit 1; }
need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || die "required tool not found: $t"; done; }

# ---- configuration ----------------------------------------------------------
SITE_ENV_FILES="$HPC_ROOT/config/site.env"
[ -f "$HPC_ROOT/config/site.local.env" ] && SITE_ENV_FILES="$SITE_ENV_FILES $HPC_ROOT/config/site.local.env"
for _f in $SITE_ENV_FILES; do
  # shellcheck disable=SC1090
  . "$_f"
done
unset _f

case "$ARCH" in
  arm64) RPM_ARCH=aarch64 ;;
  amd64) RPM_ARCH=x86_64 ;;
  *) die "ARCH must be arm64 or amd64 (got '$ARCH')" ;;
esac

INVENTORY="${HPC_INVENTORY:-$HPC_ROOT/config/inventory}"
PROJECTS_FILE="${HPC_PROJECTS_FILE:-$HPC_ROOT/config/projects.txt}"
SECRETS_DIR="${HPC_SECRETS_DIR:-$HPC_ROOT/secrets}"
CACHE_DIR="${HPC_CACHE_DIR:-$HPC_ROOT/.cache}"
BUNDLE_DIR="$CACHE_DIR/bundle/$ARCH"
case "$HPC_SSH_CONFIG" in /*) ;; *) HPC_SSH_CONFIG="$HPC_ROOT/$HPC_SSH_CONFIG" ;; esac

# ---- inventory --------------------------------------------------------------
_inv() { grep -v '^[[:space:]]*#' "$INVENTORY" | awk 'NF>=3'; }
all_hosts()     { _inv | awk '{print $1}'; }
hosts_by_role() { _inv | awk -v r="$1" '$2==r {print $1}'; }
host_ip()       { _inv | awk -v h="$1" '$1==h {print $3}'; }
host_role()     { _inv | awk -v h="$1" '$1==h {print $2}'; }
admin_host()    { hosts_by_role admin | head -1; }
admin_ip()      { host_ip "$(admin_host)"; }

# "name ip" lines for every host; consumed by node scripts as HPC_HOSTS.
hosts_table()   { _inv | awk '{print $1" "$3" "$2}'; }

# ---- secrets ----------------------------------------------------------------
# Every credential is generated once and kept under secrets/ (0600, gitignored).
secret() { # secret <name> [length] -> prints the value, generating it on first use
  local f="$SECRETS_DIR/$1" len="${2:-32}"
  if [ ! -s "$f" ]; then
    mkdir -p "$(dirname "$f")"; chmod 700 "$SECRETS_DIR"
    ( umask 077; head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-"$len" | tr -d '\n' >"$f" )
    [ "$(wc -c <"$f" | tr -d ' ')" -eq "$len" ] || { rm -f "$f"; die "could not generate secret $1"; }
  fi
  cat "$f"
}

# ---- remote execution -------------------------------------------------------
hssh() { ssh -F "$HPC_SSH_CONFIG" -o BatchMode=yes -o LogLevel=ERROR "$@"; }

# node_run <host> <script> [KEY=VALUE ...]
# Runs a node script as root on <host> (staged in root-only tmpfs, stdin closed,
# so commands that read stdin cannot eat the script). It sees every site.env setting,
# the inventory (HPC_HOSTS), its own identity and any extra KEY=VALUE given.
node_run() {
  local host="$1" script="$2"; shift 2
  [ -f "$script" ] || die "node script not found: $script"
  {
    echo 'set -euo pipefail; set -a'
    cat $SITE_ENV_FILES
    printf 'RPM_ARCH=%q\n' "$RPM_ARCH"
    printf 'HPC_HOSTS=%q\n' "$(hosts_table)"
    printf 'NODE_NAME=%q\nNODE_IP=%q\nNODE_ROLE=%q\n' "$host" "$(host_ip "$host")" "$(host_role "$host")"
    printf 'ADMIN_NAME=%q\nADMIN_IP=%q\n' "$(admin_host)" "$(admin_ip)"
    local kv
    for kv in "$@"; do printf '%s=%q\n' "${kv%%=*}" "${kv#*=}"; done
    echo 'set +a'
    cat "$HPC_ROOT/lib/node.sh" "$script"
  } | hssh "$host" 'sudo -n sh -c '\''umask 077; f=$(mktemp /run/hpc-node.XXXXXX) && cat >"$f" && bash "$f" </dev/null; rc=$?; rm -f "$f"; exit $rc'\'''
}

# node_put <host> <local-path> <remote-path> [mode]   (single file, as root)
node_put() {
  local host="$1" src="$2" dst="$3" mode="${4:-0644}"
  hssh "$host" "sudo -n install -D -m $mode /dev/stdin $(printf '%q' "$dst")" <"$src"
}

# node_sync <host> <local-dir> <remote-dir>   (directory tree, as root, incremental)
node_sync() {
  local host="$1" src="$2" dst="$3"
  hssh "$host" "sudo -n mkdir -p $(printf '%q' "$dst")"
  rsync -rlt --delete --rsync-path='sudo -n rsync' \
    -e "ssh -F $(printf '%q' "$HPC_SSH_CONFIG") -o BatchMode=yes -o LogLevel=ERROR" \
    "$src/" "$host:$dst/"
}

# admin_kubectl ... : kubectl on the admin node with the cluster-admin kubeconfig
admin_kubectl() {
  local args="" a
  for a in "$@"; do args="$args $(printf '%q' "$a")"; done
  hssh "$(admin_host)" "sudo -n /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml $args"
}

wait_for() { # wait_for <description> <timeout-seconds> <command...>
  local what="$1" timeout="$2" start; shift 2
  start=$(date +%s)
  until "$@" >/dev/null 2>&1; do
    [ $(( $(date +%s) - start )) -lt "$timeout" ] || die "timed out after ${timeout}s waiting for $what"
    sleep 5
  done
}
