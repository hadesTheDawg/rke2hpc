#!/usr/bin/env bash
# DESC: two TLS registries on the admin node (system: authenticated; user: read-only) + image load
# Usage: hpcctl run registry [install|load]   (default: both)
. "$HPC_ROOT/lib/common.sh"
a=$(admin_host)

cmd_install() {
  node_run "$a" "$HPC_MODULE_DIR/node/registry.sh" \
    "PULL_PASSWORD=$(secret registry-pull)" "PUSH_PASSWORD=$(secret registry-push)" \
    "HTTP_SECRET=$(secret registry-http-secret)"
  ok "registries running on $a"
}
cmd_load() {
  node_run "$a" "$HPC_MODULE_DIR/node/load-images.sh" "PUSH_PASSWORD=$(secret registry-push)"
  ok "images loaded"
}

case "${1:-all}" in
  install) cmd_install ;;
  load)    cmd_load ;;
  all)     cmd_install; cmd_load ;;
  *) die "usage: hpcctl run registry [install|load]" ;;
esac
